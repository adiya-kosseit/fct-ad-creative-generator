import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "backend"))

os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ["TABLE_NAME"] = "fct-adgen-test-history"
os.environ["ARTIFACTS_BUCKET"] = "fct-adgen-test-artifacts"
os.environ["GEMINI_PARAM_NAME"] = "/fct-adgen/gemini-api-key"
os.environ["GEMINI_MODEL"] = "gemini-3.8-flash"


@pytest.fixture
def aws():
    """Таблица, бакет и параметр SSM — как их создаёт Terraform."""
    with mock_aws():
        ddb = boto3.client("dynamodb")
        ddb.create_table(
            TableName=os.environ["TABLE_NAME"],
            AttributeDefinitions=[
                {"AttributeName": "requestId", "AttributeType": "S"},
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "createdAt", "AttributeType": "S"},
            ],
            KeySchema=[{"AttributeName": "requestId", "KeyType": "HASH"}],
            GlobalSecondaryIndexes=[{
                "IndexName": "byCreatedAt",
                "KeySchema": [
                    {"AttributeName": "pk", "KeyType": "HASH"},
                    {"AttributeName": "createdAt", "KeyType": "RANGE"},
                ],
                "Projection": {"ProjectionType": "ALL"},
                "ProvisionedThroughput": {"ReadCapacityUnits": 5, "WriteCapacityUnits": 5},
            }],
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5},
        )
        boto3.client("s3").create_bucket(Bucket=os.environ["ARTIFACTS_BUCKET"])
        boto3.client("ssm").put_parameter(
            Name=os.environ["GEMINI_PARAM_NAME"], Value="test-key", Type="SecureString"
        )

        import gemini
        import storage

        storage.reset_clients()
        gemini._api_key = None
        yield
        storage.reset_clients()
        gemini._api_key = None


class FakeContext:
    aws_request_id = "test-req"

    def get_remaining_time_in_millis(self):
        return 29_000


@pytest.fixture
def ctx():
    return FakeContext()
