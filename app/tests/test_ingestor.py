import json
import time

import pytest
from fastapi.testclient import TestClient

from aetherpay import ingestor, signature

KEY = b"k" * 32


class FakeKeys:
    def keys(self):
        return [KEY]


class FakeCache:
    def __init__(self, down=False):
        self.store = {}
        self.down = down

    def get(self, key):
        if self.down:
            raise ConnectionError("cache down")
        return self.store.get(key)

    def set(self, key, value, nx=False, ex=None):
        if self.down:
            raise ConnectionError("cache down")
        if nx and key in self.store:
            return None
        self.store[key] = value.encode() if isinstance(value, str) else value
        return True

    def delete(self, key):
        self.store.pop(key, None)


class FakeSqs:
    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    def send_message(self, **kwargs):
        if self.fail:
            raise RuntimeError("sqs down")
        self.sent.append(kwargs)


def client(monkeypatch, sqs=None, cache=None):
    sqs = sqs or FakeSqs()
    cache = cache or FakeCache()
    monkeypatch.setattr(ingestor, "key_provider", lambda: FakeKeys())
    monkeypatch.setattr(ingestor, "dedup_cache", lambda: cache)
    monkeypatch.setattr(ingestor, "sqs", lambda: sqs)
    return TestClient(ingestor.app), sqs, cache


def signed(body: bytes, partner="bank_a", event_id="evt-1"):
    ts = int(time.time())
    digest = signature.sign(KEY, ts, body, partner=partner, event_id=event_id)
    return {
        "X-AetherPay-Signature": f"t={ts},v1={digest}",
        "X-AetherPay-Event-Id": event_id,
    }


def test_accepts_signed_webhook_and_enqueues(monkeypatch):
    c, sqs, _ = client(monkeypatch)
    body = json.dumps({"amount": "10.00"}).encode()
    r = c.post("/webhooks/bank_a", content=body, headers=signed(body))
    assert r.status_code == 202
    assert json.loads(sqs.sent[0]["MessageBody"])["event_id"] == "evt-1"


def test_duplicate_is_acknowledged_but_not_enqueued_twice(monkeypatch):
    c, sqs, _ = client(monkeypatch)
    body = b"{}"
    assert c.post("/webhooks/bank_a", content=body, headers=signed(body)).status_code == 202
    assert c.post("/webhooks/bank_a", content=body, headers=signed(body)).status_code == 200
    assert len(sqs.sent) == 1


def test_bad_signature_is_rejected(monkeypatch):
    c, sqs, _ = client(monkeypatch)
    headers = signed(b"{}")
    r = c.post("/webhooks/bank_a", content=b'{"tampered":true}', headers=headers)
    assert r.status_code == 401
    assert sqs.sent == []


@pytest.mark.parametrize(
    "path,event_id",
    [("/webhooks/bank_a", "evt-other"), ("/webhooks/bank_b", "evt-1")],
)
def test_captured_request_cannot_be_replayed_under_a_new_identity(monkeypatch, path, event_id):
    c, sqs, _ = client(monkeypatch)
    body = b'{"amount":"10.00"}'
    headers = signed(body)  # signed for bank_a / evt-1
    headers["X-AetherPay-Event-Id"] = event_id
    assert c.post(path, content=body, headers=headers).status_code == 401
    assert sqs.sent == []


def test_enqueue_failure_returns_503_and_leaves_no_marker(monkeypatch):
    cache = FakeCache()
    c, _, _ = client(monkeypatch, sqs=FakeSqs(fail=True), cache=cache)
    body = b"{}"
    assert c.post("/webhooks/bank_a", content=body, headers=signed(body)).status_code == 503
    assert cache.store == {}  # nothing remembered, so the partner's retry is accepted


def test_crash_between_enqueue_and_marker_is_safe(monkeypatch):
    # Old bug: the marker was written before SQS, so a process killed in between
    # left a marker and the retry got 200 "duplicate" with nothing enqueued.
    # Now the marker is written only after the enqueue: simulate the crash by
    # an enqueue that succeeded with no marker written, then the retry.
    sqs, cache = FakeSqs(), FakeCache()
    c, _, _ = client(monkeypatch, sqs=sqs, cache=cache)

    class Crash(Exception):
        pass

    def crash(*_):
        raise Crash("process killed after the enqueue")

    monkeypatch.setattr(ingestor, "_cache_remember", crash)
    body = b"{}"
    with pytest.raises(Crash):
        c.post("/webhooks/bank_a", content=body, headers=signed(body))
    assert len(sqs.sent) == 1 and cache.store == {}
    monkeypatch.undo()
    c, _, _ = client(monkeypatch, sqs=sqs, cache=cache)
    assert c.post("/webhooks/bank_a", content=body, headers=signed(body)).status_code == 202
    assert len(sqs.sent) == 2  # enqueued again; the ledger keeps one journal row


def test_marker_never_exists_without_an_enqueue(monkeypatch):
    sqs, cache = FakeSqs(fail=True), FakeCache()
    c, _, _ = client(monkeypatch, sqs=sqs, cache=cache)
    for _ in range(3):
        assert c.post("/webhooks/bank_a", content=b"{}", headers=signed(b"{}")).status_code == 503
    assert cache.store == {}


def test_cache_outage_still_enqueues(monkeypatch):
    c, sqs, _ = client(monkeypatch, cache=FakeCache(down=True))
    assert c.post("/webhooks/bank_a", content=b"{}", headers=signed(b"{}")).status_code == 202
    assert len(sqs.sent) == 1


def test_same_event_id_with_different_payload_is_rejected(monkeypatch):
    c, sqs, _ = client(monkeypatch)
    assert c.post("/webhooks/bank_a", content=b'{"a":1}', headers=signed(b'{"a":1}')).status_code == 202
    assert c.post("/webhooks/bank_a", content=b'{"a":2}', headers=signed(b'{"a":2}')).status_code == 409
    assert len(sqs.sent) == 1


def test_oversized_body_rejected_before_reading_it(monkeypatch):
    c, sqs, _ = client(monkeypatch)
    body = b"x" * (ingestor.settings().max_body_bytes + 1)
    assert c.post("/webhooks/bank_a", content=body, headers=signed(body)).status_code == 413
    assert sqs.sent == []


def test_healthz(monkeypatch):
    c, _, _ = client(monkeypatch)
    assert c.get("/healthz").json()["status"] == "ok"
