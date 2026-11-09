import boto3

from aetherpay.cache import iam_auth_token


def test_iam_auth_token_is_a_presigned_connect_url():
    session = boto3.session.Session(
        aws_access_key_id="AKIDEXAMPLE",
        aws_secret_access_key="secret",
        aws_session_token="token",
        region_name="us-east-1",
    )
    token = iam_auth_token("my-group", "my-user", "us-east-1", session=session)

    assert token.startswith("my-group/?")
    assert "Action=connect" in token
    assert "User=my-user" in token
    assert "X-Amz-Signature=" in token
    assert "X-Amz-Expires=900" in token
    assert not token.startswith("https://")
