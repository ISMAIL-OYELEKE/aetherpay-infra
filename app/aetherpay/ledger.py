"""Ledger journal operations on the MRSC DynamoDB table.

Every write is a single-item conditional write (MRSC tables do not support
multi-item transactions), and conditional writes on MRSC are linearizable
across regions. That gives us:

* idempotent journaling: ``attribute_not_exists(pk)`` on ``TXN#<id>``
* a monotonic fencing epoch on ``FENCE#<shard>`` for settlement authority
* single-claim batches: ``attribute_not_exists(pk)`` on ``BATCH#<id>``

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
    def acquire_lease(self, shard: str, holder: str, duration: int) -> Lease | None:
        """Take or renew the settlement lease. Returns None if another holder has it."""
        now = int(time.time())
        try:
            out = self._db.update_item(
                TableName=self._table,
                Key={"pk": {"S": f"FENCE#{shard}"}, "sk": {"S": "LEASE"}},
                UpdateExpression=(
                    "SET epoch = if_not_exists(epoch, :zero) + :inc, holder = :me, expires_at = :exp"
                ),
                ConditionExpression="attribute_not_exists(pk) OR expires_at < :now OR holder = :me",
                ExpressionAttributeValues={
                    ":zero": {"N": "0"},
                    ":inc": {"N": "1"},
                    ":me": {"S": holder},
                    ":exp": {"N": str(now + duration)},
                    ":now": {"N": str(now)},
                },
                ReturnValues="ALL_NEW",
            )
        except ClientError as exc:
            if _conditional_failed(exc):
                return None
            raise
        attrs = out["Attributes"]
        return Lease(
            epoch=int(attrs["epoch"]["N"]),
            holder=attrs["holder"]["S"],
            expires_at=float(attrs["expires_at"]["N"]),
            acquired_monotonic=time.monotonic(),
            duration=duration,
        )

    def assert_lease(self, shard: str, lease: Lease, safety_margin: int) -> None:
        """Self-fence: stop if the lease is nearly expired or someone else bumped the epoch."""
        if lease.remaining() < safety_margin:
            raise LeaseLost("lease expiring; fencing self")
        out = self._db.get_item(
            TableName=self._table,
            Key={"pk": {"S": f"FENCE#{shard}"}, "sk": {"S": "LEASE"}},
            ConsistentRead=True,
        )
        item = out.get("Item")
        if not item or int(item["epoch"]["N"]) != lease.epoch or item["holder"]["S"] != lease.holder:
            raise LeaseLost("epoch moved on; another region holds settlement authority")

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
