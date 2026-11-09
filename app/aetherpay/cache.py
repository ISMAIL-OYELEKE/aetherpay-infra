"""ElastiCache (Valkey) client with IAM authentication.

There is no cache password. The task role signs a short-lived (15 min) SigV4
token for the ``elasticache:Connect`` action, which the server validates.
Connections use TLS (``transit_encryption_mode = required``).
"""

from __future__ import annotations

from urllib.parse import urlencode

import boto3
import redis
from botocore.awsrequest import AWSRequest
from botocore.model import ServiceId
from botocore.signers import RequestSigner

TOKEN_TTL_SECONDS = 900


def iam_auth_token(replication_group_id: str, user: str, region: str, session=None) -> str:
    session = session or boto3.session.Session()
    credentials = session.get_credentials()
    signer = RequestSigner(
        service_id=ServiceId("elasticache"),  # botocore calls .hyphenize() on it
        region_name=region,
        signing_name="elasticache",
        signature_version="v4",
        credentials=credentials,
        event_emitter=session._session.get_component("event_emitter"),  # noqa: SLF001
    )
    query = urlencode({"Action": "connect", "User": user})
    request = AWSRequest(method="GET", url=f"https://{replication_group_id}/?{query}")
    signed = signer.generate_presigned_url(
        {
            "method": request.method,
            "url": request.url,
            "body": {},
            "headers": {},
            "context": {},
        },
        operation_name="connect",
        expires_in=TOKEN_TTL_SECONDS,
        region_name=region,
    )
    return signed.removeprefix("https://")


class _IamCredentialProvider(redis.CredentialProvider):
    def __init__(self, replication_group_id: str, user: str, region: str) -> None:
        self._rg = replication_group_id
        self._user = user
        self._region = region

    def get_credentials(self):  # called on every new connection, so tokens stay fresh
        return self._user, iam_auth_token(self._rg, self._user, self._region)


def connect(host: str, port: int, user: str, replication_group_id: str, region: str) -> redis.Redis:
    if not replication_group_id:  # local development against a plain Valkey container
        return redis.Redis(host=host, port=port, socket_timeout=2)
    return redis.Redis(
        host=host,
        port=port,
        ssl=True,
        socket_timeout=2,
        socket_connect_timeout=2,
        health_check_interval=30,
        credential_provider=_IamCredentialProvider(replication_group_id, user, region),
    )
