"""Webhook ingestor: verify, de-duplicate, enqueue, acknowledge.

A ``202`` is returned only after the event is durably in SQS. Partners retry
anything else, which gives at-least-once delivery; exactly-once *settlement*
is enforced downstream by the ledger's conditional writes.
"""

from __future__ import annotations

import json
import logging
import time
from functools import lru_cache

import boto3
import uvicorn
from fastapi import FastAPI, Header, HTTPException, Request, Response

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


@lru_cache(maxsize=1)
def sqs():
    return boto3.client("sqs", region_name=settings().region)


@lru_cache(maxsize=1)
def dedup_cache():
    s = settings()
    return cache.connect(s.cache_host, s.cache_port, s.cache_user, s.cache_replication_id, s.region)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    # Liveness only: dependency outages must not make ECS kill every task at once.
    return {"status": "ok", "region_role": settings().region_role}


@app.post("/webhooks/{partner}", status_code=202)
async def receive(
    partner: str,
    request: Request,
    response: Response,
    x_aetherpay_signature: str | None = Header(default=None),
    x_aetherpay_event_id: str | None = Header(default=None),
) -> dict[str, str]:
    s = settings()
    if not partner.isidentifier() or len(partner) > 64:
        raise HTTPException(status_code=404, detail="unknown partner")
    if not x_aetherpay_event_id or len(x_aetherpay_event_id) > 128:
        raise HTTPException(status_code=400, detail="missing or invalid event id")

    body = await request.body()
    if len(body) > s.max_body_bytes:
        raise HTTPException(status_code=413, detail="payload too large")

    try:
        signature.verify(x_aetherpay_signature, body, key_provider().keys())
    except signature.SignatureError as exc:
        LOG.warning("rejected webhook partner=%s event=%s reason=%s", partner, x_aetherpay_event_id, exc)
        raise HTTPException(status_code=401, detail="invalid signature") from exc

    dedup_key = f"dedup:{partner}:{x_aetherpay_event_id}"
    first_seen = dedup_cache().set(dedup_key, "1", nx=True, ex=s.dedup_ttl_seconds)
    if not first_seen:
        response.status_code = 200
        return {"status": "duplicate", "event_id": x_aetherpay_event_id}

    try:
        sqs().send_message(
            QueueUrl=s.queue_url,
            MessageBody=json.dumps(
                {
                    "partner": partner,
                    "event_id": x_aetherpay_event_id,
                    "received_at": int(time.time()),
                    "payload": body.decode("utf-8"),
                }
            ),
            MessageAttributes={"partner": {"DataType": "String", "StringValue": partner}},
        )
    except Exception:
        # Let the partner retry: forget the dedup marker so the retry is accepted.
        dedup_cache().delete(dedup_key)
        LOG.exception("enqueue failed partner=%s event=%s", partner, x_aetherpay_event_id)
        raise HTTPException(status_code=503, detail="temporarily unavailable") from None

    return {"status": "accepted", "event_id": x_aetherpay_event_id}


def main() -> None:
    uvicorn.run(app, host="0.0.0.0", port=settings().port, proxy_headers=True, access_log=False)  # noqa: S104


if __name__ == "__main__":
    main()
