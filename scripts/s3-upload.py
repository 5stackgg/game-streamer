#!/usr/bin/env python3
"""Minimal S3 uploader — signed V4 PUT, no boto3 dep.

Usage: s3-upload.py <local-file> <bucket>/<key>

Env: S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, S3_REGION (default us-east-1).
"""
import datetime
import hashlib
import hmac
import os
import sys
from urllib.parse import urlparse

import requests


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, date: str, region: str, service: str) -> bytes:
    k = _sign(("AWS4" + secret).encode("utf-8"), date)
    k = _sign(k, region)
    k = _sign(k, service)
    return _sign(k, "aws4_request")


def put(local_path: str, dest: str) -> None:
    endpoint = os.environ["S3_ENDPOINT"].rstrip("/")
    access = os.environ["S3_ACCESS_KEY"]
    secret = os.environ["S3_SECRET_KEY"]
    region = os.environ.get("S3_REGION", "us-east-1")

    bucket, _, key = dest.partition("/")
    if not key:
        raise SystemExit("destination must be <bucket>/<key>")

    parsed = urlparse(endpoint)
    host = parsed.netloc
    url = f"{endpoint}/{bucket}/{key}"

    with open(local_path, "rb") as fh:
        body = fh.read()
    payload_hash = hashlib.sha256(body).hexdigest()

    now = datetime.datetime.utcnow()
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date = now.strftime("%Y%m%d")

    canonical_uri = f"/{bucket}/{key}"
    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = (
        f"PUT\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    )
    credential_scope = f"{date}/{region}/s3/aws4_request"
    string_to_sign = (
        f"AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n"
        f"{hashlib.sha256(canonical_request.encode('utf-8')).hexdigest()}"
    )
    signature = hmac.new(
        _signing_key(secret, date, region, "s3"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    authorization = (
        f"AWS4-HMAC-SHA256 Credential={access}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    r = requests.put(
        url,
        data=body,
        headers={
            "Host": host,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
            "Authorization": authorization,
        },
        timeout=120,
    )
    r.raise_for_status()
    print(f"uploaded: s3://{bucket}/{key} ({len(body)} bytes)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: s3-upload.py <local> <bucket>/<key>")
    put(sys.argv[1], sys.argv[2])
