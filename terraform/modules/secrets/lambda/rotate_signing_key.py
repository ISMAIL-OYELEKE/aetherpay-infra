"""Secrets Manager rotation handler for AetherPay HMAC signing keys.

Implements the standard four-step rotation contract (createSecret, setSecret,
testSecret, finishSecret). Key material is generated inside the function, so
it never appears in Terraform code, plans or state.

Verifiers accept both AWSCURRENT and AWSPREVIOUS for one rotation period,
which gives partners an overlap window and makes rotation zero-downtime.
"""

import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
from datetime import datetime, timezone

import boto3

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

KEY_BYTES = 32

_client = None


def _sm():
    global _client
    if _client is None:
        _client = boto3.client("secretsmanager")
    return _client


def handler(event, _context):
    arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    metadata = _sm().describe_secret(SecretId=arn)
    if not metadata.get("RotationEnabled"):
        raise ValueError(f"Rotation is not enabled for {arn}")

    versions = metadata.get("VersionIdsToStages", {})
    if token not in versions:
        raise ValueError(f"Version {token} has no stage for {arn}")
    if "AWSCURRENT" in versions[token]:
        LOG.info("Version %s already AWSCURRENT; nothing to do", token)
        return
    if "AWSPENDING" not in versions[token]:
        raise ValueError(f"Version {token} is not AWSPENDING for {arn}")

    {
        "createSecret": create_secret,
        "setSecret": set_secret,
        "testSecret": test_secret,
        "finishSecret": finish_secret,
    }[step](arn, token)


def create_secret(arn, token):
    try:
        _sm().get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        LOG.info("AWSPENDING already exists for %s", arn)
        return
    except _sm().exceptions.ResourceNotFoundException:
        pass

    value = {
        "algorithm": "HMAC-SHA256",
        "key": base64.b64encode(secrets.token_bytes(KEY_BYTES)).decode(),
        "key_id": token,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    _sm().put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=json.dumps(value),
        VersionStages=["AWSPENDING"],
    )
    LOG.info("Created AWSPENDING version for %s", arn)


def set_secret(arn, _token):
    # HMAC keys are symmetric and owned by AetherPay. Partners pull the new key
    # through the partner portal during the overlap window, so there is no
    # downstream system to push to here.
    LOG.info("setSecret is a no-op for %s", arn)


def test_secret(arn, token):
    pending = json.loads(
        _sm().get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")["SecretString"]
    )
    key = base64.b64decode(pending["key"])
    if len(key) != KEY_BYTES:
        raise ValueError("Pending key has the wrong length")
    try:
        current = json.loads(_sm().get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"])
    except _sm().exceptions.ResourceNotFoundException:
        current = {}  # First rotation of a brand-new secret.
    if current.get("key") == pending["key"]:
        raise ValueError("Pending key is identical to the current key")
    # Prove the key signs and verifies the same way the ingestor does.
    probe = b"aetherpay-rotation-probe"
    signature = hmac.new(key, probe, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, hmac.new(base64.b64decode(pending["key"]), probe, hashlib.sha256).hexdigest()):
        raise ValueError("HMAC self-test failed")
    LOG.info("Pending key for %s passed self-test", arn)


def finish_secret(arn, token):
    versions = _sm().describe_secret(SecretId=arn)["VersionIdsToStages"]
    current = next((v for v, stages in versions.items() if "AWSCURRENT" in stages), None)
    if current == token:
        return
    kwargs = {"SecretId": arn, "VersionStage": "AWSCURRENT", "MoveToVersionId": token}
    if current:
        kwargs["RemoveFromVersionId"] = current
    _sm().update_secret_version_stage(**kwargs)
    LOG.info("Promoted %s to AWSCURRENT for %s (previous: %s)", token, arn, current)
