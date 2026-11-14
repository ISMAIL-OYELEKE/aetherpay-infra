"""Webhook signature verification.

Partners sign each webhook with HMAC-SHA256 over the canonical string
``"<timestamp>.<partner>.<event id>.<raw body>"`` and send
``X-AetherPay-Signature: t=<unix seconds>,v1=<hex digest>``.

The partner (URL path) and event ID (header) are part of the signed string
because they become the de-duplication key and the journal identity. If they
were unsigned, a captured request could be replayed inside the time window
under a new event ID or partner path and be journaled again. Neither may
contain ``.`` (checked here), so the canonical string cannot be re-split.

Verification accepts any of the candidate keys (AWSCURRENT and AWSPREVIOUS),
so a key rotation never rejects in-flight partner traffic, and it rejects
stale timestamps to block replays.
"""

from __future__ import annotations

import hashlib
import hmac
import re
import time
from collections.abc import Iterable
from dataclasses import dataclass

DEFAULT_TOLERANCE_SECONDS = 300
PARTNER_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
EVENT_ID_RE = re.compile(r"^[A-Za-z0-9_:\-]{1,128}$")


class SignatureError(Exception):
    """Raised when a webhook signature is missing, malformed, stale or wrong."""


@dataclass(frozen=True)
class ParsedSignature:
    timestamp: int
    signatures: tuple[str, ...]


def parse_header(header: str | None) -> ParsedSignature:
    if not header:
        raise SignatureError("missing signature header")
    timestamp: int | None = None
    signatures: list[str] = []
    for part in header.split(","):
        key, _, value = part.strip().partition("=")
        if key == "t":
            try:
                timestamp = int(value)
            except ValueError as exc:
                raise SignatureError("invalid timestamp") from exc
        elif key == "v1" and value:
            signatures.append(value.lower())
    if timestamp is None or not signatures:
        raise SignatureError("malformed signature header")
    return ParsedSignature(timestamp, tuple(signatures))


def canonical(timestamp: int, partner: str, event_id: str, body: bytes) -> bytes:
    if not PARTNER_RE.fullmatch(partner):
        raise SignatureError("invalid partner")
    if not EVENT_ID_RE.fullmatch(event_id):
        raise SignatureError("invalid event id")
    return f"{timestamp}.{partner}.{event_id}.".encode() + body


def sign(key: bytes, timestamp: int, body: bytes, *, partner: str, event_id: str) -> str:
    return hmac.new(key, canonical(timestamp, partner, event_id, body), hashlib.sha256).hexdigest()


def verify(
    header: str | None,
    body: bytes,
    keys: Iterable[bytes],
    *,
    partner: str,
    event_id: str,
    now: float | None = None,
    tolerance: int = DEFAULT_TOLERANCE_SECONDS,
) -> None:
    parsed = parse_header(header)
    current = time.time() if now is None else now
    if abs(current - parsed.timestamp) > tolerance:
        raise SignatureError("timestamp outside tolerance")
    for key in keys:
        expected = sign(key, parsed.timestamp, body, partner=partner, event_id=event_id)
        if any(hmac.compare_digest(expected, candidate) for candidate in parsed.signatures):
            return
    raise SignatureError("signature mismatch")
