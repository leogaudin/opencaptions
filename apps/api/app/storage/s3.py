"""boto3-based S3-compatible storage wrapper.

A single boto3 client serves both the bundled Garage and AWS S3.
Switch via S3_ENDPOINT_URL: any URL means an S3-compatible store, empty means real AWS S3.
"""

from __future__ import annotations

import logging
from typing import Any

import boto3
from botocore.client import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError

from app.core.config import settings

logger = logging.getLogger(__name__)


class StorageError(Exception):
    """Wrapped storage error for callers."""


class ObjectNotFoundError(StorageError):
    """The key does not exist."""


class RangeNotSatisfiableError(StorageError):
    """The requested byte range lies outside the object."""


# Calls run in the default thread pool (up to 32 at once); a smaller connection pool
# makes the extra ones open connections only to throw them away.
_POOL_CONNECTIONS = 32


def _make_s3_client() -> Any:
    """Create a boto3 S3 client wired to the configured backend."""
    return boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint_url or None,
        aws_access_key_id=settings.s3_access_key,
        aws_secret_access_key=settings.s3_secret_key,
        region_name=settings.s3_region,
        config=BotoConfig(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            connect_timeout=10,
            read_timeout=60,
            retries={"max_attempts": 3, "mode": "standard"},
            max_pool_connections=_POOL_CONNECTIONS,
        ),
    )


_client = _make_s3_client()


def ensure_bucket() -> None:
    """Idempotent bucket creation. Safe to call on every startup."""
    try:
        _client.head_bucket(Bucket=settings.s3_bucket)
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in {"404", "NoSuchBucket"}:
            _client.create_bucket(Bucket=settings.s3_bucket)
            logger.info("Created bucket %s", settings.s3_bucket)
        else:
            raise StorageError(f"head_bucket failed: {e}") from e


def upload_file(key: str, path: str, content_type: str | None = None) -> None:
    """Upload a local file."""
    extra: dict[str, Any] = {}
    if content_type:
        extra["ContentType"] = content_type
    try:
        _client.upload_file(path, settings.s3_bucket, key, ExtraArgs=extra)
    except (BotoCoreError, ClientError) as e:
        raise StorageError(f"upload_file failed: {e}") from e


def download_file(key: str, path: str) -> None:
    """Download s3://{bucket}/{key} to a local path."""
    try:
        _client.download_file(settings.s3_bucket, key, path)
    except (BotoCoreError, ClientError) as e:
        raise StorageError(f"download_file failed: {e}") from e


def put_object_bytes(key: str, body: bytes, content_type: str) -> None:
    """Write bytes to an object."""
    try:
        _client.put_object(Bucket=settings.s3_bucket, Key=key, Body=body, ContentType=content_type)
    except (BotoCoreError, ClientError) as e:
        raise StorageError(f"put_object failed: {e}") from e


def get_object_bytes(key: str) -> bytes:
    """Read an object into memory."""
    obj = open_object(key)
    try:
        body: bytes = obj["Body"].read()
        return body
    except (BotoCoreError, ClientError) as e:
        raise StorageError(f"get_object failed: {e}") from e
    finally:
        obj["Body"].close()


def open_object(key: str, byte_range: str | None = None) -> dict[str, Any]:
    """Start reading an object (or a ``Range`` of it); the caller reads and closes ``Body``."""
    extra = {"Range": byte_range} if byte_range else {}
    try:
        obj: dict[str, Any] = _client.get_object(Bucket=settings.s3_bucket, Key=key, **extra)
        return obj
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in {"404", "NoSuchKey"}:
            raise ObjectNotFoundError(key) from e
        if code in {"416", "InvalidRange"}:
            raise RangeNotSatisfiableError(key) from e
        raise StorageError(f"open_object failed: {e}") from e
    except BotoCoreError as e:
        raise StorageError(f"open_object failed: {e}") from e


def delete_object(key: str) -> None:
    try:
        _client.delete_object(Bucket=settings.s3_bucket, Key=key)
    except (BotoCoreError, ClientError) as e:
        raise StorageError(f"delete_object failed: {e}") from e


def object_exists(key: str) -> bool:
    """Return True if the object at `key` exists (HEAD request)."""
    try:
        _client.head_object(Bucket=settings.s3_bucket, Key=key)
        return True
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in {"404", "NoSuchKey"}:
            return False
        raise StorageError(f"object_exists failed: {e}") from e


def list_prefix(prefix: str) -> list[str]:
    """Return all object keys that start with `prefix`."""
    keys: list[str] = []
    paginator = _client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=settings.s3_bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            keys.append(item["Key"])
    return keys


def delete_prefix(prefix: str) -> int:
    """Delete every object whose key starts with `prefix`. Returns count."""
    deleted = 0
    paginator = _client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=settings.s3_bucket, Prefix=prefix):
        contents = page.get("Contents", [])
        if not contents:
            continue
        objs = [{"Key": item["Key"]} for item in contents]
        response = _client.delete_objects(Bucket=settings.s3_bucket, Delete={"Objects": objs})
        # A 200 can still carry per-key failures; leaving those behind unreported
        # is how a "deleted" project keeps its video.
        failed = response.get("Errors") or []
        if failed:
            raise StorageError(f"delete_prefix left {len(failed)} object(s): {failed[0]}")
        deleted += len(objs)
    return deleted


def presigned_url(key: str, expires_in: int = 3600, method: str = "get_object") -> str:
    """Generate a presigned URL for a download (default) or upload."""
    try:
        url: str = _client.generate_presigned_url(
            ClientMethod=method,
            Params={"Bucket": settings.s3_bucket, "Key": key},
            ExpiresIn=expires_in,
        )
        return url
    except (BotoCoreError, ClientError) as e:
        raise StorageError(f"presigned_url failed: {e}") from e


def health_check() -> bool:
    """Return True if the storage backend is reachable + the bucket exists."""
    try:
        _client.head_bucket(Bucket=settings.s3_bucket)
        return True
    except Exception:
        return False
