import json

from fastapi.testclient import TestClient

from aetherpay import ingestor, signature

KEY = b"k" * 32


class FakeKeys:
    def keys(self):
        return [KEY]


class FakeCache:
    def __init__(self):
        self.store = {}

    def set(self, key, value, nx=False, ex=None):
        if nx and key in self.store:
            return None
        self.store[key] = value
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


def signed(body: bytes):
    import time

    ts = int(time.time())
    return {
        "X-AetherPay-Signature": f"t={ts},v1={signature.sign(KEY, ts, body)}",
        "X-AetherPay-Event-Id": "evt-1",
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


def test_enqueue_failure_returns_503_and_allows_retry(monkeypatch):
    cache = FakeCache()
    c, _, _ = client(monkeypatch, sqs=FakeSqs(fail=True), cache=cache)
    body = b"{}"
    assert c.post("/webhooks/bank_a", content=body, headers=signed(body)).status_code == 503
    assert cache.store == {}  # dedup marker removed so the partner's retry is accepted


def test_healthz(monkeypatch):
    c, _, _ = client(monkeypatch)
    assert c.get("/healthz").json()["status"] == "ok"
