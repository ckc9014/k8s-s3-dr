"""
S3-event backup validator.

Triggered by SQS messages originating from S3 ObjectCreated events.

Checks the size of backup data objects. Two classes of messages are
skipped rather than validated:
  - Kasten/Kopia metadata files (kopia.*, xn0_*, _log_*) — legitimately small
  - S3 TestEvent notifications — AWS's one-time health check, not a backup
"""
import json
import os
import boto3

s3 = boto3.client("s3")
MIN_SIZE = int(os.environ.get("MIN_SIZE_BYTES", "64"))

# Kasten/Kopia metadata filenames that are legitimately tiny.
METADATA_NAMES = {
    "kopia.blobcfg",
    "kopia.repository",
    "kopia.maintenance",
}

# Filename prefixes that mark metadata (not real backup data).
METADATA_PREFIXES = ("xn0_", "_log_")


def is_metadata(key: str) -> bool:
    """Return True if the S3 key is Kasten/Kopia metadata, not data."""
    name = key.rsplit("/", 1)[-1]
    if name in METADATA_NAMES:
        return True
    if name.startswith(METADATA_PREFIXES):
        return True
    return False


def is_test_event(body: dict) -> bool:
    """
    Return True if the SQS body is an S3 TestEvent notification.

    S3 sends this once when the bucket notification is first configured,
    to verify it can reach the destination. It has no "Records" array
    and no S3 object data.
    """
    return (
        body.get("Service") == "Amazon S3"
        or body.get("Event") == "s3:TestEvent"
    )


def handler(event, context):
    failures = 0
    checked = 0
    skipped = 0

    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
        except (KeyError, TypeError, json.JSONDecodeError) as exc:
            print(f"ERROR: malformed SQS record ({exc}): {record}")
            failures += 1
            continue

        # Skip AWS S3 TestEvent notifications (sent once per notification
        # configuration, for verification).
        if is_test_event(body):
            print(f"SKIP (S3 test event): {body.get('Event', 'unknown')}")
            skipped += 1
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

            if is_metadata(key):
                print(f"SKIP (metadata): {bucket}/{key}")
                skipped += 1
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

    print(
        f"Validated {checked} object(s), "
        f"skipped {skipped} (metadata/test), "
        f"{failures} failure(s)"
    )

    if failures:
        raise RuntimeError(f"{failures} backup validation failure(s)")