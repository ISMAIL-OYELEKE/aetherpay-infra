"""Ledger journal operations on the MRSC DynamoDB table.

Every write is a single-item conditional write (MRSC tables do not support
multi-item transactions), and conditional writes on MRSC are linearizable
across regions. That gives us:

* idempotent journaling: ``attribute_not_exists(pk)`` on ``TXN#<id>``
* a monotonic fencing epoch on ``FENCE#<shard>`` for settlement authority
* single-claim batches: ``attribute_not_exists(pk)`` on ``BATCH#<id>``

Lease item ``FENCE#<shard> / LEASE`` (one schema, used by workers and by the
operator runbook):

* ``region``     the region allowed to settle. Changed only by an operator
                 (``TRANSFER_*`` below, the ADR-001 T+13 command), never by
                 lease expiry. A former primary that recovers can therefore
                 never take authority back on its own.
* ``holder``     the worker (``<region>/<hostname>``) holding the lease inside
                 that region, or ``""`` right after a transfer.
* ``epoch``      bumped on every change of holder or region: the fencing token.
* ``expires_at`` lease expiry, epoch seconds.

See docs/ADR-001-Disaster-Recovery.md.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass

from botocore.exceptions import ClientError


class LeaseLost(Exception):
    """This worker no longer holds the settlement lease and must stop settling."""


def _conditional_failed(exc: ClientError) -> bool:
    return exc.response["Error"]["Code"] == "ConditionalCheckFailedException"


@dataclass
class Lease:
    epoch: int
    holder: str
    expires_at: float  # epoch seconds, as stored
    acquired_monotonic: float
    duration: int

    def remaining(self) -> float:
        return self.duration - (time.monotonic() - self.acquired_monotonic)


def _lease_key(shard: str) -> dict:
    return {"pk": {"S": f"FENCE#{shard}"}, "sk": {"S": "LEASE"}}


# Lease expressions. ``region`` is a DynamoDB reserved word, hence ``#r``.
# The operator transfer is the exact command in ADR-001 (T+13); a test checks
# that the ADR quotes these strings, so the runbook and the code cannot drift.
RENEW_UPDATE = "SET expires_at = :exp"
RENEW_CONDITION = "#r = :region AND holder = :me"
TAKEOVER_UPDATE = "SET epoch = epoch + :one, holder = :me, expires_at = :exp"
TAKEOVER_CONDITION = "#r = :region AND expires_at < :now"
BOOTSTRAP_UPDATE = "SET epoch = :one, #r = :region, holder = :me, expires_at = :exp"
BOOTSTRAP_CONDITION = "attribute_not_exists(pk)"
TRANSFER_UPDATE = "SET #r = :to, epoch = epoch + :one, holder = :none, expires_at = :zero"
TRANSFER_CONDITION = "#r = :from"


class Ledger:
    def __init__(self, client, table: str, region: str) -> None:
        self._db = client
        self._table = table
        self._region = region

    # ----------------------------------------------------------- journal
    def journal(self, settlement_id: str, entry: dict, *, epoch: int | None = None) -> bool:
        """Append an immutable journal row. Returns False if it already exists (duplicate)."""
        item = {
            "pk": {"S": f"TXN#{settlement_id}"},
            "sk": {"S": "ENTRY#0"},
            "body": {"S": json.dumps(entry, sort_keys=True)},
            "region": {"S": self._region},
            "written_at": {"N": str(int(time.time()))},
        }
        if epoch is not None:
            item["epoch"] = {"N": str(epoch)}
        try:
            self._db.put_item(
                TableName=self._table, Item=item, ConditionExpression="attribute_not_exists(pk)"
            )
            return True
        except ClientError as exc:
            if _conditional_failed(exc):
                return False
            raise

    # ------------------------------------------------------------- lease
    def acquire_lease(
        self, shard: str, holder: str, duration: int, *, bootstrap: bool = False
    ) -> Lease | None:
        """Renew our lease, or take it over inside our authorized region.

        Returns None when another worker holds it or settlement authority
        belongs to another region. ``bootstrap`` (primary role only) creates
        the lease item the very first time, with this region authorized.
        """
        # Start the local clock *before* the request: the stored expiry was
        # computed before the call too, so request latency can only shorten
        # the time we believe we hold the lease, never lengthen it.
        started = time.monotonic()
        now = int(time.time())
        values = {
            ":me": {"S": holder},
            ":region": {"S": self._region},
            ":exp": {"N": str(now + duration)},
        }
        attempts = [
            (RENEW_UPDATE, RENEW_CONDITION, {}),
            (TAKEOVER_UPDATE, TAKEOVER_CONDITION, {":one": {"N": "1"}, ":now": {"N": str(now)}}),
        ]
        if bootstrap:
            attempts.append((BOOTSTRAP_UPDATE, BOOTSTRAP_CONDITION, {":one": {"N": "1"}}))
        for update, condition, extra in attempts:
            try:
                out = self._db.update_item(
                    TableName=self._table,
                    Key=_lease_key(shard),
                    UpdateExpression=update,
                    ConditionExpression=condition,
                    ExpressionAttributeNames={"#r": "region"},
                    ExpressionAttributeValues={**values, **extra},
                    ReturnValues="ALL_NEW",
                )
            except ClientError as exc:
                if _conditional_failed(exc):
                    continue
                raise
            attrs = out["Attributes"]
            return Lease(
                epoch=int(attrs["epoch"]["N"]),
                holder=attrs["holder"]["S"],
                expires_at=float(attrs["expires_at"]["N"]),
                acquired_monotonic=started,
                duration=duration,
            )
        return None

    def assert_lease(self, shard: str, lease: Lease, safety_margin: int) -> None:
        """Self-fence: stop if the lease is nearly expired, or the epoch, holder or region moved on.

        Checked before *and after* the read: a slow read must not let us act on
        a lease that expired while we were waiting for the answer.
        """
        if lease.remaining() < safety_margin:
            raise LeaseLost("lease expiring; fencing self")
        out = self._db.get_item(TableName=self._table, Key=_lease_key(shard), ConsistentRead=True)
        item = out.get("Item")
        if (
            not item
            or int(item["epoch"]["N"]) != lease.epoch
            or item["holder"]["S"] != lease.holder
            or item.get("region", {}).get("S") != self._region
        ):
            raise LeaseLost("epoch moved on; another worker or region holds settlement authority")
        if lease.remaining() < safety_margin:
            raise LeaseLost("lease expired during the check; fencing self")

    # ------------------------------------------------------------ batches
    def claim_batch(self, batch_id: str, lease: Lease) -> bool:
        try:
            self._db.put_item(
                TableName=self._table,
                Item={
                    "pk": {"S": f"BATCH#{batch_id}"},
                    "sk": {"S": "CLAIM"},
                    "epoch": {"N": str(lease.epoch)},
                    "region": {"S": self._region},
                    "claimed_at": {"N": str(int(time.time()))},
                },
                ConditionExpression="attribute_not_exists(pk)",
            )
            return True
        except ClientError as exc:
            if _conditional_failed(exc):
                return False
            raise
