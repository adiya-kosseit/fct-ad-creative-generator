"""DynamoDB (история) и S3 (архив генераций)."""

import json
import os
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key
from botocore.config import Config
from botocore.exceptions import ClientError

HISTORY_PK = "REQ"          # постоянный ключ раздела для GSI byCreatedAt
HISTORY_INDEX = "byCreatedAt"

_CONFIG = Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 3, "mode": "standard"})
_table = None
_s3 = None


def _get_table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb", config=_CONFIG).Table(os.environ["TABLE_NAME"])
    return _table


def _get_s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", config=_CONFIG)
    return _s3


def reset_clients():
    """Для тестов."""
    global _table, _s3
    _table = None
    _s3 = None


def save_generation(item):
    _get_table().put_item(
        Item={**item, "pk": HISTORY_PK},
        ConditionExpression="attribute_not_exists(requestId)",
    )


def list_history(limit):
    resp = _get_table().query(
        IndexName=HISTORY_INDEX,
        KeyConditionExpression=Key("pk").eq(HISTORY_PK),
        ScanIndexForward=False,  # новые сверху
        Limit=limit,
    )
    return resp.get("Items", [])


def update_variants(request_id, variants, updated_at):
    """True — обновлено, False — такого запроса нет."""
    try:
        _get_table().update_item(
            Key={"requestId": request_id},
            UpdateExpression="SET variants = :v, #c = :c, updatedAt = :u, edited = :e",
            ConditionExpression="attribute_exists(requestId)",
            ExpressionAttributeNames={"#c": "count"},  # COUNT — зарезервированное слово
            ExpressionAttributeValues={
                ":v": variants,
                ":c": len(variants),
                ":u": updated_at,
                ":e": True,
            },
        )
        return True
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return False
        raise


def archive_generation(request_id, created_at, document):
    key = f"generations/{created_at[:10]}/{request_id}.json"
    _get_s3().put_object(
        Bucket=os.environ["ARTIFACTS_BUCKET"],
        Key=key,
        Body=json.dumps(document, ensure_ascii=False, indent=2, default=_json_default).encode("utf-8"),
        ContentType="application/json; charset=utf-8",
        ServerSideEncryption="AES256",
    )
    return key


def _json_default(obj):
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    raise TypeError(f"Not serializable: {type(obj).__name__}")
