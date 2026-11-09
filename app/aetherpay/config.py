"""Runtime configuration.

Only non-secret coordinates come from the environment (endpoints, ARNs, table
names). Secret values are fetched at runtime from Secrets Manager through the
VPC endpoint, using the task role.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None:
        raise RuntimeError(f"missing required environment variable {name}")
    return value


@dataclass(frozen=True)
class Settings:
    environment: str = field(default_factory=lambda: _env("AETHERPAY_ENV", "local"))
    region_role: str = field(default_factory=lambda: _env("AETHERPAY_REGION_ROLE", "primary"))
    region: str = field(default_factory=lambda: _env("AWS_REGION", "us-east-1"))
    queue_url: str = field(default_factory=lambda: _env("QUEUE_URL", ""))
    ledger_table: str = field(default_factory=lambda: _env("LEDGER_TABLE", ""))
    cache_host: str = field(default_factory=lambda: _env("CACHE_HOST", "localhost"))
    cache_port: int = field(default_factory=lambda: int(_env("CACHE_PORT", "6379")))
    cache_user: str = field(default_factory=lambda: _env("CACHE_USER", "default"))
    cache_replication_id: str = field(default_factory=lambda: _env("CACHE_REPLICATION_ID", ""))
    partner_hmac_key_arn: str = field(default_factory=lambda: _env("PARTNER_HMAC_KEY_ARN", ""))
    port: int = field(default_factory=lambda: int(_env("PORT", "8080")))
    max_body_bytes: int = 256 * 1024
    dedup_ttl_seconds: int = 24 * 3600
    lease_seconds: int = 30
    lease_safety_margin_seconds: int = 10
