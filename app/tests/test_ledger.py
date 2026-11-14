"""Ledger and lease semantics, using a fake that evaluates the real expressions."""

import json
import pathlib
import time

import pytest

from aetherpay import ledger as ledger_mod
from aetherpay.ledger import TRANSFER_CONDITION, TRANSFER_UPDATE, LeaseLost, Ledger
from tests.fake_dynamo import FakeDynamo

ADR = pathlib.Path(__file__).resolve().parents[2] / "docs" / "ADR-001-Disaster-Recovery.md"
LEASE_KEY = ("FENCE#settlement", "LEASE")


@pytest.fixture
def db():
    return FakeDynamo()


def expire(db):
    db.items[LEASE_KEY]["expires_at"] = {"N": str(int(time.time()) - 1)}


def operator_transfer(db, frm, to):
    """The ADR-001 T+13 command, with the same expression strings."""
    return db.update_item(
        TableName="t",
        Key={"pk": {"S": "FENCE#settlement"}, "sk": {"S": "LEASE"}},
        UpdateExpression=TRANSFER_UPDATE,
        ConditionExpression=TRANSFER_CONDITION,
        ExpressionAttributeNames={"#r": "region"},
        ExpressionAttributeValues={
            ":to": {"S": to},
            ":from": {"S": frm},
            ":one": {"N": "1"},
            ":none": {"S": ""},
            ":zero": {"N": "0"},
        },
        ReturnValues="ALL_NEW",
    )


def test_journal_is_idempotent_across_regions(db):
    east1 = Ledger(db, "t", "us-east-1")
    east2 = Ledger(db, "t", "us-east-2")
    assert east1.journal("bank:evt-1", {"amount": 10}) is True
    # The recovered primary replays the same event after failover: no double record.
    assert east2.journal("bank:evt-1", {"amount": 10}) is False


def test_only_the_primary_creates_the_lease(db):
    assert Ledger(db, "t", "us-east-2").acquire_lease("settlement", "us-east-2/b", 30) is None
    first = Ledger(db, "t", "us-east-1").acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    assert first is not None and first.epoch == 1
    assert db.items[LEASE_KEY]["region"]["S"] == "us-east-1"


def test_only_one_holder_inside_the_region(db):
    led = Ledger(db, "t", "us-east-1")
    led.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    assert led.acquire_lease("settlement", "us-east-1/b", 30, bootstrap=True) is None
    renewed = led.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    assert renewed.epoch == 1  # renewal does not bump the fencing token


def test_same_region_takeover_after_expiry_bumps_epoch_and_fences_old_worker(db):
    led = Ledger(db, "t", "us-east-1")
    old = led.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    expire(db)
    new = led.acquire_lease("settlement", "us-east-1/b", 30)
    assert new.epoch == old.epoch + 1
    with pytest.raises(LeaseLost):
        led.assert_lease("settlement", old, safety_margin=0)
    led.assert_lease("settlement", new, safety_margin=0)


def test_secondary_cannot_take_authority_just_because_the_lease_expired(db):
    Ledger(db, "t", "us-east-1").acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    expire(db)
    assert Ledger(db, "t", "us-east-2").acquire_lease("settlement", "us-east-2/b", 30) is None


def test_operator_transfer_promotes_secondary_and_excludes_old_primary(db):
    east1 = Ledger(db, "t", "us-east-1")
    east2 = Ledger(db, "t", "us-east-2")
    old = east1.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)

    operator_transfer(db, "us-east-1", "us-east-2")

    new = east2.acquire_lease("settlement", "us-east-2/b", 30)
    assert new is not None and new.epoch == old.epoch + 2  # transfer + takeover
    # The old primary is fenced, cannot renew, and cannot win it back after expiry.
    with pytest.raises(LeaseLost):
        east1.assert_lease("settlement", old, safety_margin=0)
    assert east1.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True) is None
    expire(db)
    assert east1.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True) is None
    # A second transfer with a stale source region is rejected.
    with pytest.raises(Exception, match="ConditionalCheckFailed"):
        operator_transfer(db, "us-east-1", "us-east-2")


def test_adr_runbook_uses_the_code_lease_schema():
    text = ADR.read_text()
    assert f"'{TRANSFER_UPDATE}'" in text
    assert f"'{TRANSFER_CONDITION}'" in text
    assert "holder_region" not in text


def test_lease_clock_starts_before_the_request(db, monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(ledger_mod.time, "monotonic", lambda: clock[0])
    led = Ledger(db, "t", "us-east-1")
    led.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    real_update = db.update_item

    def slow_update(**kw):
        clock[0] += 25  # the request took 25 s
        return real_update(**kw)

    db.update_item = slow_update
    lease = led.acquire_lease("settlement", "us-east-1/a", 30)  # renewal, one call
    assert lease.remaining() == pytest.approx(5)


def test_lease_rechecked_after_a_slow_read(db, monkeypatch):
    clock = [0.0]
    monkeypatch.setattr(ledger_mod.time, "monotonic", lambda: clock[0])
    led = Ledger(db, "t", "us-east-1")
    lease = led.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    real_get = db.get_item

    def slow_get(**kw):
        clock[0] += 25  # read returned after the lease is inside the margin
        return real_get(**kw)

    db.get_item = slow_get
    with pytest.raises(LeaseLost, match="during the check"):
        led.assert_lease("settlement", lease, safety_margin=10)


def test_batch_can_be_claimed_once(db):
    led = Ledger(db, "t", "us-east-1")
    lease = led.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    assert led.claim_batch("2026-11-09T02", lease) is True
    assert led.claim_batch("2026-11-09T02", lease) is False


def test_self_fence_when_lease_nearly_expired(db):
    led = Ledger(db, "t", "us-east-1")
    lease = led.acquire_lease("settlement", "us-east-1/a", 30, bootstrap=True)
    with pytest.raises(LeaseLost, match="expiring"):
        led.assert_lease("settlement", lease, safety_margin=31)


def test_settler_poll_leaves_room_for_the_safety_margin():
    from aetherpay.settler import poll_wait_seconds

    # Defaults: 30 s lease, 10 s margin. A 20 s poll would leave exactly the
    # margin and fence the worker on every loop.
    wait = poll_wait_seconds(30, 10)
    assert 30 - wait > 10
    assert poll_wait_seconds(300, 10) == 20  # never above the SQS maximum
    assert poll_wait_seconds(5, 10) == 1


# ------------------------------------------------- settler loop (real step())
class FakeSqs:
    def __init__(self, messages=()):
        self.messages = list(messages)
        self.deleted = []

    def receive_message(self, **_):
        out, self.messages = self.messages, []
        return {"Messages": out}

    def delete_message(self, ReceiptHandle, **_):
        self.deleted.append(ReceiptHandle)


class S:
    def __init__(self, role):
        self.region_role = role
        self.queue_url = "q"
        self.lease_seconds = 30
        self.lease_safety_margin_seconds = 10


def msg(event_id, rh):
    return {"Body": json.dumps({"partner": "bank_a", "event_id": event_id}), "ReceiptHandle": rh}


def test_secondary_settler_loop_takes_over_after_transfer(db):
    from aetherpay.settler import step

    east1 = Ledger(db, "t", "us-east-1")
    east2 = Ledger(db, "t", "us-east-2")
    primary_lease = step(east1, FakeSqs(), S("primary"), "us-east-1/a", None, 1)
    assert primary_lease is not None

    # Before the transfer the secondary loop journals but never settles.
    assert step(east2, FakeSqs([msg("e1", "r1")]), S("secondary"), "us-east-2/b", None, 1) is None
    assert db.items[("TXN#bank_a:e1", "ENTRY#0")]["region"]["S"] == "us-east-2"

    operator_transfer(db, "us-east-1", "us-east-2")
    secondary_lease = step(east2, FakeSqs(), S("secondary"), "us-east-2/b", None, 1)
    assert secondary_lease is not None
    # The old primary's next loop loses the lease and stays out.
    assert step(east1, FakeSqs(), S("primary"), "us-east-1/a", primary_lease, 1) is None


def test_one_bad_message_does_not_stop_the_batch(db):
    from aetherpay.settler import step

    sqs = FakeSqs([{"Body": "not json", "ReceiptHandle": "bad"}, msg("e2", "good")])
    step(Ledger(db, "t", "us-east-1"), sqs, S("primary"), "us-east-1/a", None, 1)
    assert sqs.deleted == ["good"]  # the bad one stays on the queue for the DLQ
