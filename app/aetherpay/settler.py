"""Settlement worker: drain the ingestion queue into the ledger journal.

Journaling is idempotent and safe in any region. Settlement side effects
(batch submission to payment networks) happen only while this worker holds
the fencing lease; see ledger.Ledger.
"""

from __future__ import annotations

import json
import logging
import signal
import socket

import boto3

from .config import Settings
from .ledger import LeaseLost, Ledger

LOG = logging.getLogger("aetherpay.settler")
logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","msg":"%(message)s"}')

SHARD = "settlement"
_running = True


def _stop(*_):
    global _running
    _running = False


def process(ledger: Ledger, message: dict, epoch: int | None) -> None:
    event = json.loads(message["Body"])
    settlement_id = f'{event["partner"]}:{event["event_id"]}'
    created = ledger.journal(settlement_id, event, epoch=epoch)
    LOG.info("journal %s settlement=%s", "appended" if created else "duplicate", settlement_id)


def poll_wait_seconds(lease_seconds: int, safety_margin: int) -> int:
    """How long one SQS long poll may block while we hold the lease.

    The lease is renewed once per loop, then checked after the poll. The poll
    must therefore leave more than ``safety_margin`` of the lease, or the
    worker fences itself on every loop even though nobody else has the lease.
    """
    return max(1, min(20, (lease_seconds - safety_margin) // 2))


def run() -> None:
    s = Settings()
    sqs = boto3.client("sqs", region_name=s.region)
    ledger = Ledger(boto3.client("dynamodb", region_name=s.region), s.ledger_table, s.region)
    holder = f"{s.region}/{socket.gethostname()}"
    lease = None
    wait = poll_wait_seconds(s.lease_seconds, s.lease_safety_margin_seconds)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    while _running:
        if s.region_role == "primary":
            held = lease is not None
            lease = ledger.acquire_lease(SHARD, holder, s.lease_seconds)  # take or renew
            if lease is None and held:
                LOG.warning("lease taken over elsewhere; journaling only")
            elif lease is None:
                LOG.info("lease held elsewhere; journaling only")

        resp = sqs.receive_message(
            QueueUrl=s.queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=wait, VisibilityTimeout=120
        )
        for message in resp.get("Messages", []):
            process(ledger, message, lease.epoch if lease else None)
            sqs.delete_message(QueueUrl=s.queue_url, ReceiptHandle=message["ReceiptHandle"])

        if lease is not None:
            try:
                ledger.assert_lease(SHARD, lease, s.lease_safety_margin_seconds)
                # Batch submission to payment networks would happen here, guarded by
                # ledger.claim_batch(batch_id, lease) and the network's idempotency key.
            except LeaseLost as exc:
                LOG.warning("fenced: %s", exc)
                lease = None

    LOG.info("settler stopped")


if __name__ == "__main__":
    run()
