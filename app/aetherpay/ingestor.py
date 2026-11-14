"""Webhook ingestor: verify, enqueue, acknowledge, then remember.

Commit point: a ``202`` is returned only after SQS has durably accepted the
message. The cache is never the reason an event is acknowledged:

* The de-duplication marker is written *after* the enqueue succeeds, so a
  marker always means "already enqueued". A crash between the two leaves no
  marker; the partner's retry is enqueued again and the ledger's conditional
  write drops the duplicate (``TXN#<partner>:<event id>``).
* Overlapping retries may both enqueue; the ledger keeps one.
* If the cache is down the request is still enqueued (fail open on the cache,
  never on durability).
* The marker stores a hash of the body, so the same event ID with a different
  payload is rejected with ``409`` instead of being reported as a duplicate.

That gives at-least-once delivery into SQS; exactly-once *journaling* is
enforced downstream by the ledger. The SQS queue is regional, so an event
accepted by a region that is then lost is only as durable as that queue
(see the RPO table in ADR-001).
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from functools import lru_cache

import boto3
import uvicorn
from botocore.config import Config
from fastapi import FastAPI, Header, HTTPException, Request, Response
from starlette.concurrency import run_in_threadpool

from . import cache, signature
from .config import Settings
from .keys import SigningKeyProvider

LOG = logging.getLogger("aetherpay.ingestor")
logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","msg":"%(message)s"}')

app = FastAPI(title="AetherPay webhook ingestor", docs_url=None, redoc_url=None, openapi_url=None)


@lru_cache(maxsize=1)
def settings() -> Settings:
    return Settings()


@lru_cache(maxsize=1)
def key_provider() -> SigningKeyProvider:
    return SigningKeyProvider(settings().partner_hmac_key_arn)


# Bounded SDK timeouts: a slow dependency must fail the request (partner
# retries) rather than hold a worker thread for the default 60 s.
SDK_CONFIG = Config(connect_timeout=2, read_timeout=5, retries={"max_attempts": 3, "mode": "standard"})


@lru_cache(maxsize=1)
def sqs():
    return boto3.client("sqs", region_name=settings().region, config=SDK_CONFIG)


@lru_cache(maxsize=1)
def dedup_cache():
    s = settings()
    return cache.connect(s.cache_host, s.cache_port, s.cache_user, s.cache_replication_id, s.region)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    # Liveness only: dependency outages must not make ECS kill every task at once.
    return {"status": "ok", "region_role": settings().region_role}


async def read_body_capped(request: Request, limit: int) -> bytes:
    """Read the body but stop as soon as it exceeds ``limit`` (never buffer more)."""
    declared = request.headers.get("content-length")
    if declared is not None and (not declared.isdigit() or int(declared) > limit):
        raise HTTPException(status_code=413, detail="payload too large")
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            raise HTTPException(status_code=413, detail="payload too large")
        chunks.append(chunk)
    return b"".join(chunks)


def _cache_get(key: str) -> bytes | None:
    try:
        return dedup_cache().get(key)
    except Exception:  # cache outage: carry on, the ledger still de-duplicates
        LOG.warning("dedup cache read failed; continuing without it")
        return None


def _cache_remember(key: str, body_hash: str, ttl: int) -> None:
    try:
        dedup_cache().set(key, body_hash, ex=ttl)
    except Exception:
        LOG.warning("dedup cache write failed; a retry will be enqueued again (harmless)")


@app.post("/webhooks/{partner}", status_code=202)
async def receive(
    partner: str,
    request: Request,
    response: Response,
    x_aetherpay_signature: str | None = Header(default=None),
    x_aetherpay_event_id: str | None = Header(default=None),
) -> dict[str, str]:
    s = settings()
    if not signature.PARTNER_RE.fullmatch(partner):
        raise HTTPException(status_code=404, detail="unknown partner")
    if not x_aetherpay_event_id or not signature.EVENT_ID_RE.fullmatch(x_aetherpay_event_id):
        raise HTTPException(status_code=400, detail="missing or invalid event id")
    event_id = x_aetherpay_event_id

    body = await read_body_capped(request, s.max_body_bytes)

    keys = await run_in_threadpool(key_provider().keys)
    try:
        signature.verify(x_aetherpay_signature, body, keys, partner=partner, event_id=event_id)
    except signature.SignatureError as exc:
        LOG.warning("rejected webhook partner=%s event=%s reason=%s", partner, event_id, exc)
        raise HTTPException(status_code=401, detail="invalid signature") from exc

    dedup_key = f"dedup:{partner}:{event_id}"
    body_hash = hashlib.sha256(body).hexdigest()
    seen = await run_in_threadpool(_cache_get, dedup_key)
    if seen is not None:
        if (seen.decode() if isinstance(seen, bytes) else str(seen)) != body_hash:
            LOG.warning("event id reused with a different payload partner=%s event=%s", partner, event_id)
            raise HTTPException(status_code=409, detail="event id already used with a different payload")
        # Safe: the marker is only written after a successful enqueue.
        response.status_code = 200
        return {"status": "duplicate", "event_id": event_id}

    message = json.dumps(
        {
            "partner": partner,
            "event_id": event_id,
            "body_sha256": body_hash,
            "received_at": int(time.time()),
            "payload": body.decode("utf-8", errors="replace"),
        }
    )
    try:
        await run_in_threadpool(
            sqs().send_message,
            QueueUrl=s.queue_url,
            MessageBody=message,
            MessageAttributes={"partner": {"DataType": "String", "StringValue": partner}},
        )
    except Exception:
        LOG.exception("enqueue failed partner=%s event=%s", partner, event_id)
        raise HTTPException(status_code=503, detail="temporarily unavailable") from None

    # Commit point passed. Remember it so plain retries get a cheap 200.
    await run_in_threadpool(_cache_remember, dedup_key, body_hash, s.dedup_ttl_seconds)
    return {"status": "accepted", "event_id": event_id}


def main() -> None:
    uvicorn.run(app, host="0.0.0.0", port=settings().port, proxy_headers=True, access_log=False)  # noqa: S104


if __name__ == "__main__":
    main()
