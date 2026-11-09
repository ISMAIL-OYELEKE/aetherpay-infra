"""Ledger semantics against a tiny in-memory fake of the DynamoDB calls we use."""

import time

import pytest
from botocore.exceptions import ClientError

from aetherpay.ledger import LeaseLost, Ledger


def _ccf():
    return ClientError({"Error": {"Code": "ConditionalCheckFailedException", "Message": "x"}}, "Op")


class FakeDynamo:
    """Implements just enough of put_item/update_item/get_item for the ledger's conditions."""

    def __init__(self):
        self.items = {}

    def _key(self, key):
        return key["pk"]["S"], key["sk"]["S"]

    def put_item(self, TableName, Item, ConditionExpression=None):
        k = self._key(Item)
        if ConditionExpression == "attribute_not_exists(pk)" and k in self.items:
            raise _ccf()
        self.items[k] = Item

    def get_item(self, TableName, Key, ConsistentRead=False):
        item = self.items.get(self._key(Key))
        return {"Item": item} if item else {}

    def update_item(self, TableName, Key, ExpressionAttributeValues, ReturnValues, **_):
        k = self._key(Key)
        v = ExpressionAttributeValues
        cur = self.items.get(k)
        if cur is not None:
            expired = int(cur["expires_at"]["N"]) < int(v[":now"]["N"])
            if not (expired or cur["holder"]["S"] == v[":me"]["S"]):
                raise _ccf()
        epoch = (int(cur["epoch"]["N"]) if cur else 0) + 1
        new = {
            "pk": Key["pk"],
            "sk": Key["sk"],
            "epoch": {"N": str(epoch)},
            "holder": v[":me"],
            "expires_at": v[":exp"],
        }
        self.items[k] = new
        return {"Attributes": new}


@pytest.fixture
def db():
    return FakeDynamo()


def test_journal_is_idempotent_across_regions(db):
    east1 = Ledger(db, "t", "us-east-1")
    east2 = Ledger(db, "t", "us-east-2")
    assert east1.journal("bank:evt-1", {"amount": 10}) is True
    # The recovered primary replays the same event after failover: no double record.
    assert east2.journal("bank:evt-1", {"amount": 10}) is False


def test_only_one_lease_holder(db):
    led = Ledger(db, "t", "us-east-1")
    first = led.acquire_lease("settlement", "us-east-1/a", 30)
    assert first is not None and first.epoch == 1
    assert led.acquire_lease("settlement", "us-east-2/b", 30) is None


def test_failover_bumps_epoch_and_fences_old_holder(db):
    led = Ledger(db, "t", "us-east-1")
    old = led.acquire_lease("settlement", "us-east-1/a", 30)
    # Simulate expiry, then the secondary takes over with a higher epoch.
    db.items[("FENCE#settlement", "LEASE")]["expires_at"] = {"N": str(int(time.time()) - 1)}
    new = led.acquire_lease("settlement", "us-east-2/b", 30)
    assert new.epoch == old.epoch + 1
    with pytest.raises(LeaseLost):
        led.assert_lease("settlement", old, safety_margin=0)
    led.assert_lease("settlement", new, safety_margin=0)


def test_batch_can_be_claimed_once(db):
    led = Ledger(db, "t", "us-east-1")
    lease = led.acquire_lease("settlement", "us-east-1/a", 30)
    assert led.claim_batch("2026-11-09T02", lease) is True
    assert led.claim_batch("2026-11-09T02", lease) is False


def test_self_fence_when_lease_nearly_expired(db):
    led = Ledger(db, "t", "us-east-1")
    lease = led.acquire_lease("settlement", "us-east-1/a", 30)
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
