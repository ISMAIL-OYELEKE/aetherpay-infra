import pytest

from aetherpay import signature

KEY = b"k" * 32
OLD = b"o" * 32
BODY = b'{"amount":"10.00","currency":"USD"}'
NOW = 1_800_000_000


def header(key: bytes = KEY, ts: int = NOW, body: bytes = BODY) -> str:
    return f"t={ts},v1={signature.sign(key, ts, body)}"


def test_valid_signature_with_current_key():
    signature.verify(header(), BODY, [KEY, OLD], now=NOW)


def test_previous_key_still_accepted_during_rotation_overlap():
    signature.verify(header(OLD), BODY, [KEY, OLD], now=NOW)


def test_tampered_body_rejected():
    with pytest.raises(signature.SignatureError, match="mismatch"):
        signature.verify(header(), BODY + b" ", [KEY], now=NOW)


def test_unknown_key_rejected():
    with pytest.raises(signature.SignatureError):
        signature.verify(header(b"x" * 32), BODY, [KEY, OLD], now=NOW)


@pytest.mark.parametrize("skew", [301, -301])
def test_replay_outside_tolerance_rejected(skew):
    with pytest.raises(signature.SignatureError, match="tolerance"):
        signature.verify(header(ts=NOW + skew), BODY, [KEY], now=NOW)


@pytest.mark.parametrize("bad", [None, "", "v1=abc", "t=notanumber,v1=abc", "t=1"])
def test_malformed_headers_rejected(bad):
    with pytest.raises(signature.SignatureError):
        signature.verify(bad, BODY, [KEY], now=NOW)
