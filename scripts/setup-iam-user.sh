#!/usr/bin/env bash
#
# Create the Kasten IAM user, attach the S3 policy scoped to the backup
# bucket, generate an access key, and write both values into .env.
#
# Idempotent — safe to re-run.
#
# Reads:
#   .tf-output.json   (bucket name + ARN — created by `make terraform-apply`)
#   .env              (must exist; K10_AWS_* lines are updated in place)
#
# Uses AWS SSO profile (AWS_PROFILE) for IAM operations.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# ---- config ---------------------------------------------------------------
TF_OUTPUT="${PROJECT_ROOT}/.tf-output.json"
PROFILE="${AWS_PROFILE:-k8s-dr-eu}"
USER_NAME="${K10_IAM_USER:-kasten-s3-backup}"
POLICY_NAME="kasten-s3-access"

# ---- pre-flight -----------------------------------------------------------
if [ ! -f "$TF_OUTPUT" ]; then
  echo "ERROR: ${TF_OUTPUT} not found."
  echo "       Run 'make terraform-apply' first."
  exit 1
fi

if [ ! -f .env ]; then
  echo "ERROR: .env not found."
  echo "       Run 'cp .env.example .env' first."
  exit 1
fi

# ---- resolve bucket -------------------------------------------------------
BUCKET_NAME=$(jq -r '.bucket_name.value' "$TF_OUTPUT")
BUCKET_ARN=$(jq -r '.bucket_arn.value' "$TF_OUTPUT")

: "${BUCKET_ARN:?BUCKET_ARN could not be resolved from .tf-output.json}"
: "${BUCKET_NAME:?BUCKET_NAME could not be resolved from .tf-output.json}"

echo "Bucket:     ${BUCKET_NAME}"
echo "Bucket ARN: ${BUCKET_ARN}"
echo "IAM user:   ${USER_NAME}"
echo "Profile:    ${PROFILE}"
echo ""

# ---- 1. Create user (idempotent) ------------------------------------------
echo "-> ensuring IAM user '${USER_NAME}'"
if aws iam get-user --user-name "$USER_NAME" --profile "$PROFILE" >/dev/null 2>&1; then
  echo "   user already exists — reusing"
else
  aws iam create-user --user-name "$USER_NAME" --profile "$PROFILE" >/dev/null
  echo "   created"
fi

# ---- 2. Attach inline policy (idempotent) ---------------------------------
echo "-> attaching policy '${POLICY_NAME}'"
POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT

cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "${BUCKET_ARN}",
        "${BUCKET_ARN}/*"
      ]
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name "$USER_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://${POLICY_FILE}" \
  --profile "$PROFILE"

# ---- 3. Access key handling -----------------------------------------------
echo "-> checking access keys"
KEY_COUNT=$(aws iam list-access-keys --user-name "$USER_NAME" --profile "$PROFILE" \
  --query 'length(AccessKeyMetadata)' --output text)

if [ "$KEY_COUNT" -ge 1 ]; then
  echo "   ${KEY_COUNT} access key(s) already exist for '${USER_NAME}'"
  echo "   -> NOT creating new keys (secret is unrecoverable)."
  echo ""
  echo "   If .env is already populated, you're done."
  echo "   If you need fresh keys:"
  echo "     aws iam list-access-keys --user-name ${USER_NAME} --profile ${PROFILE}"
  echo "     aws iam delete-access-key --user-name ${USER_NAME} --access-key-id <AKIA...> --profile ${PROFILE}"
  echo "     make iam-setup    # re-run"
  echo ""

  # Check if .env already has non-empty keys — if so, we're done
  if grep -qE '^K10_AWS_ACCESS_KEY_ID=.+' .env && \
     grep -qE '^K10_AWS_SECRET_ACCESS_KEY=.+' .env; then
    echo "✅ .env already has keys — nothing to do."
    exit 0
  fi

  echo "⚠️  .env is missing keys but a key exists in AWS."
  echo "    The secret cannot be recovered. Delete the key and re-run,"
  echo "    or paste the existing values manually into .env."
  exit 1
fi

echo "   no access keys found — creating one"
KEY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE" "$KEY_FILE"' EXIT

aws iam create-access-key --user-name "$USER_NAME" --profile "$PROFILE" \
  > "$KEY_FILE"

# ---- 4. Write keys to .env (no quotes) ------------------------------------
ACCESS_KEY=$(jq -r '.AccessKey.AccessKeyId'     "$KEY_FILE")
SECRET_KEY=$(jq -r '.AccessKey.SecretAccessKey' "$KEY_FILE")

echo "-> writing keys to .env"

# Ensure the lines exist before sed
if ! grep -q '^K10_AWS_ACCESS_KEY_ID=' .env; then
  echo "K10_AWS_ACCESS_KEY_ID=" >> .env
fi
if ! grep -q '^K10_AWS_SECRET_ACCESS_KEY=' .env; then
  echo "K10_AWS_SECRET_ACCESS_KEY=" >> .env
fi

if sed --version >/dev/null 2>&1; then
  sed -i "s|^K10_AWS_ACCESS_KEY_ID=.*|K10_AWS_ACCESS_KEY_ID=${ACCESS_KEY}|" .env
  sed -i "s|^K10_AWS_SECRET_ACCESS_KEY=.*|K10_AWS_SECRET_ACCESS_KEY=${SECRET_KEY}|" .env
else
  sed -i '' "s|^K10_AWS_ACCESS_KEY_ID=.*|K10_AWS_ACCESS_KEY_ID=${ACCESS_KEY}|" .env
  sed -i '' "s|^K10_AWS_SECRET_ACCESS_KEY=.*|K10_AWS_SECRET_ACCESS_KEY=${SECRET_KEY}|" .env
fi

# ---- 5. Verify ------------------------------------------------------------
echo ""
echo "-> verifying .env"
grep -E '^K10_AWS_' .env | sed 's/=.*/=<set>/'

echo ""
echo "✅ IAM user ready. Kasten can now authenticate to S3."
echo "   Next: make deploy-kasten"