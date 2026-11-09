"""Signing-key provider backed by Secrets Manager.

Returns AWSCURRENT first and AWSPREVIOUS second, cached for a short TTL, so a
rotation is picked up within minutes and the previous key keeps working for
partners that have not switched yet.
"""

from __future__ import annotations

import base64
import json
import threading
import time

import boto3
from botocore.exceptions import ClientError


class SigningKeyProvider:
    def __init__(self, secret_arn: str, *, ttl_seconds: int = 300, client=None) -> None:
        self._arn = secret_arn
        self._ttl = ttl_seconds
        self._client = client or boto3.client("secretsmanager")
        self._lock = threading.Lock()
        self._keys: list[bytes] = []
        self._expires = 0.0

    def keys(self) -> list[bytes]:
        with self._lock:
            if time.monotonic() >= self._expires or not self._keys:
                self._keys = self._load()
                self._expires = time.monotonic() + self._ttl
            return list(self._keys)

    def _load(self) -> list[bytes]:
        keys: list[bytes] = []
        for stage in ("AWSCURRENT", "AWSPREVIOUS"):
            try:
                value = self._client.get_secret_value(SecretId=self._arn, VersionStage=stage)
            except ClientError as exc:
                if exc.response["Error"]["Code"] == "ResourceNotFoundException" and stage == "AWSPREVIOUS":
                    continue  # no previous version yet (first rotation)
                raise
            keys.append(base64.b64decode(json.loads(value["SecretString"])["key"]))
        return keys
