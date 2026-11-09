"""Webhook signature verification.

Partners sign each webhook with HMAC-SHA256 over ``"<timestamp>.<raw body>"``
and send ``X-AetherPay-Signature: t=<unix seconds>,v1=<hex digest>``.

Verification accepts any of the candidate keys (AWSCURRENT and AWSPREVIOUS),
so a key rotation never rejects in-flight partner traffic, and it rejects
stale timestamps to block replays.
"""

from __future__ import annotations

import hashlib
import hmac
import time
from collections.abc import Iterable
from dataclasses import dataclass

DEFAULT_TOLERANCE_SECONDS = 300


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


def sign(key: bytes, timestamp: int, body: bytes) -> str:
    return hmac.new(key, f"{timestamp}.".encode() + body, hashlib.sha256).hexdigest()


def verify(
    header: str | None,
    body: bytes,
    keys: Iterable[bytes],
    *,
    now: float | None = None,
    tolerance: int = DEFAULT_TOLERANCE_SECONDS,
) -> None:
    parsed = parse_header(header)
    current = time.time() if now is None else now
    if abs(current - parsed.timestamp) > tolerance:
        raise SignatureError("timestamp outside tolerance")
    for key in keys:
        expected = sign(key, parsed.timestamp, body)
        if any(hmac.compare_digest(expected, candidate) for candidate in parsed.signatures):
            return
    raise SignatureError("signature mismatch")
