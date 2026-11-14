"""Settlement worker: drain the ingestion queue into the ledger journal.

Journaling is idempotent and safe in any region. Settlement side effects
(batch submission to payment networks) happen only while this worker holds
the fencing lease; see ledger.Ledger.

Every worker, in every region, tries to hold the lease on every loop. The
lease item names the one region allowed to settle, so only workers in that
region can succeed. Failover is therefore one operator write (ADR-001 T+13)
that moves ``region``; the secondary's workers pick the lease up on their
next loop, and the old primary's workers fail their next renewal.

Reference scope: payment-network submission is not implemented; the
placeholder below marks where it would run, guarded by the lease and a
batch claim.
"""

from __future__ import annotations

import json
import logging
import random
import signal
import socket
import time

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
    """Journal one queued event. Raises on failure so the caller keeps the message."""
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


def step(ledger: Ledger, sqs, s: Settings, holder: str, lease, wait: int):
    """One loop: hold the lease if we may, drain a batch, re-check the lease. Returns the lease."""
    held = lease is not None
    lease = ledger.acquire_lease(SHARD, holder, s.lease_seconds, bootstrap=s.region_role == "primary")
    if lease is not None and not held:
        LOG.info("settlement lease acquired epoch=%s holder=%s", lease.epoch, holder)
    elif lease is None and held:
        LOG.warning("lease taken over elsewhere; journaling only")

    resp = sqs.receive_message(
        QueueUrl=s.queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=wait, VisibilityTimeout=120
    )
    for message in resp.get("Messages", []):
        try:
            process(ledger, message, lease.epoch if lease else None)
        except Exception:
            # Isolate the message: it becomes visible again after the visibility
            # timeout and moves to the DLQ after maxReceiveCount.
            LOG.exception("journal failed; message left on the queue")
            continue
        sqs.delete_message(QueueUrl=s.queue_url, ReceiptHandle=message["ReceiptHandle"])

    if lease is not None:
        try:
            ledger.assert_lease(SHARD, lease, s.lease_safety_margin_seconds)
            # Payment submission would run here (not implemented: reference scope),
            # guarded by ledger.claim_batch(batch_id, lease) and by the payment
            # network enforcing the batch ID as its idempotency key.
        except LeaseLost as exc:
            LOG.warning("fenced: %s", exc)
            lease = None
    return lease


def run() -> None:
    s = Settings()
    sqs = boto3.client("sqs", region_name=s.region)
    ledger = Ledger(boto3.client("dynamodb", region_name=s.region), s.ledger_table, s.region)
    holder = f"{s.region}/{socket.gethostname()}"
    lease = None
    wait = poll_wait_seconds(s.lease_seconds, s.lease_safety_margin_seconds)
    backoff = 1.0

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    while _running:
        try:
            lease = step(ledger, sqs, s, holder, lease, wait)
            backoff = 1.0
        except Exception:
            # Transient AWS errors: drop the lease (we can no longer prove we hold
            # it), back off with jitter, and try again instead of crash-looping.
            LOG.exception("settler loop error; backing off %.1fs", backoff)
            lease = None
            time.sleep(backoff + random.random())  # noqa: S311
            backoff = min(backoff * 2, 30.0)

    LOG.info("settler stopped")


if __name__ == "__main__":
    run()
