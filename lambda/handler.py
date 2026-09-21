"""
S3-event backup validator.

Triggered by SQS messages originating from S3 ObjectCreated events.

Check the size of backup.
"""
import json
import os
import boto3

s3 = boto3.client("s3")
MIN_SIZE = int(os.environ.get("MIN_SIZE_BYTES", "1024"))


def handler(event, context):
    failures = 0
    checked = 0

    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
        except (KeyError, TypeError, json.JSONDecodeError) as exc:
            print(f"ERROR: malformed SQS record ({exc}): {record}")
            failures += 1
            continue

        s3_records = body.get("Records")
        if not s3_records:
            print(f"ERROR: SQS body missing Records: {body}")
            failures += 1
            continue

        for s3_event in s3_records:
            try:
                bucket = s3_event["s3"]["bucket"]["name"]
                key = s3_event["s3"]["object"]["key"]
            except (KeyError, TypeError) as exc:
                print(f"ERROR: malformed S3 event ({exc}): {s3_event}")
                failures += 1
                continue

            try:
                head = s3.head_object(Bucket=bucket, Key=key)
                size = head["ContentLength"]
            except Exception as exc:
                print(f"ERROR: cannot HEAD {bucket}/{key}: {exc}")
                failures += 1
                continue

            checked += 1
            if size < MIN_SIZE:
                print(f"FAIL: {bucket}/{key} is only {size} bytes (< {MIN_SIZE})")
                failures += 1
            else:
                print(f"OK: {bucket}/{key} ({size} bytes)")

    print(f"Validated {checked} object(s), {failures} failure(s)")

    if failures:
        raise RuntimeError(f"{failures} backup validation failure(s)")