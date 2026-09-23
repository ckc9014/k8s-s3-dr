# k8s-s3-dr

Cross-cluster disaster recovery lab: two Kind clusters running MongoDB,
backed up by Kasten K10 to AWS S3, validated end to end.

## What it does

- Two Kind clusters: one backs up, one restores
- MongoDB StatefulSet on both clusters
- Kasten K10 exports backups to an S3 bucket
- Restore cluster pulls the backup back and restores MongoDB
- Two independent validation layers:
  - **AWS-side (automatic):** S3 `ObjectCreated` → SQS → Lambda checks each
    backup object's size
  - **Cluster-side (manual):** checks Kasten CR status + asserts MongoDB
    document count matches the expected value

## Architecture

```
┌────────────────────────┐         ┌────────────────────────┐
│  Cluster A (source)    │         │  Cluster B (restore)   │
│  Kind: k8s-source      │         │  Kind: k8s-restore     │
│                        │         │                        │
│  MongoDB StatefulSet   │         │  MongoDB StatefulSet   │
│  Kasten K10            │         │  Kasten K10            │
│  CSI hostpath driver   │         │  CSI hostpath driver   │
│  VolumeSnapshotClass   │         │  VolumeSnapshotClass   │
└───────────┬────────────┘         └───────────▲────────────┘
            │ backup                           │ restore
            ▼                                  │
      ┌──────────────────────────────────────────┐
      │      S3 bucket (k10/...)                 │
      └───────────────┬──────────────────────────┘
                      │ ObjectCreated
                      ▼
              ┌───────────────┐     ┌────────────────┐
              │  SQS queue    │────▶│  Lambda        │
              └───────────────┘     └────────────────┘
```

## Environment support

This project runs on any OS that can run Docker + Kind. **WSL is not required.**

| Environment | Status | Notes |
|---|---|---|
| **Native Linux** | ✅ Recommended | Simplest — no virtualization layer |
| **WSL2 on Windows** | ✅ Supported | What the original author used; works well but has DNS quirks |
| **macOS** | ✅ Supported | Docker Desktop or Colima |
| **Windows (native)** | ⚠️ Not recommended | Kind + bash + make are all awkward on native Windows |

If you're on Windows, **use WSL2**. If you're on macOS or Linux, **use your native environment** — no WSL needed.

## Prerequisites

### Docker (choose one)

The Kind clusters run inside Docker containers. You need a working Docker runtime.

| Option | Best for | Cost |
|---|---|---|
| **Docker Engine** (via `apt` / `dnf`) | Native Linux | Free |
| **Docker Desktop** | Windows / macOS / WSL2 | Free for personal use; paid license required for larger companies |
| **Rancher Desktop** | Windows / macOS | Free, open source — drop-in replacement for Docker Desktop |
| **Colima** | macOS | Free, open source, lighter than Docker Desktop |

**If you're on native Linux**, install Docker Engine:

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install -y docker.io docker-compose-plugin
sudo usermod -aG docker "$USER"    # then log out and back in
docker run --rm hello-world
```

**If you're on WSL2**, install Docker Engine inside WSL (cleaner than Docker Desktop):

```bash
# Inside WSL, same as above
sudo apt update
sudo apt install -y docker.io
sudo usermod -aG docker "$USER"
# Restart WSL: from PowerShell → wsl --shutdown, then reopen
docker run --rm hello-world
```

Or use **Docker Desktop with WSL integration**:
1. Install Docker Desktop for Windows
2. Settings → Resources → WSL Integration → enable for your distro
3. Verify inside WSL: `docker run --rm hello-world`

**If you're on macOS**, use Docker Desktop or Colima:

```bash
# Colima (free alternative)
brew install colima docker
colima start --cpu 4 --memory 8
docker run --rm hello-world
```

### System resources

Kind runs real Kubernetes nodes as Docker containers. Two clusters + Kasten + MongoDB need:

| Resource | Minimum | Recommended |
|---|---|---|
| RAM for Docker | 8 GB | 12–16 GB |
| CPUs for Docker | 2 | 4+ |
| Disk | 20 GB | 40 GB |

**On WSL2**, cap WSL's memory in `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
memory=12GB
processors=6
swap=2GB
```

Then `wsl --shutdown` from PowerShell to apply.

**On macOS with Colima**, set at startup:

```bash
colima start --cpu 4 --memory 12
```

### AWS account

You need an AWS account with:

- **IAM Identity Center (SSO)** configured — so you can `aws configure sso`
- Permission to create: **S3 buckets, SQS queues, Lambda functions, IAM roles, IAM users**

Free-tier usage is fine — a lab like this costs pennies per month.

### CLI tools

All of these must be on `PATH` in the shell you'll use (WSL bash, native Linux bash, or macOS shell):

| Tool | Version | Install |
|---|---|---|
| `kind` | v0.24+ | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| `kubectl` | v1.28+ | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | v3.12+ | https://helm.sh/docs/intro/install/ |
| `terraform` | v1.5+ | https://developer.hashicorp.com/terraform/install |
| `aws` (CLI v2) | v2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| `jq` | any | `apt install jq` / `brew install jq` |
| `envsubst` | any | part of `gettext` — `apt install gettext` |
| `make` | any | `apt install make` / `brew install make` |

Quick check:

```bash
for t in kind kubectl helm terraform aws jq envsubst make docker; do
  command -v "$t" >/dev/null && echo "OK: $t" || echo "MISSING: $t"
done
```

Fix anything that says `MISSING` before continuing.

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/ckc9014/k8s-s3-dr.git
cd k8s-s3-dr
```

### 2. Configure AWS SSO

```bash
aws configure sso
```

Answer the prompts:

| Prompt | What to enter |
|---|---|
| SSO session name | `my-sso` (any short name) |
| SSO start URL | Your org's portal URL (e.g., `https://my-org.awsapps.com/start`) |
| SSO region | **Where IAM Identity Center is configured** — check AWS Console → IAM Identity Center → region selector |
| SSO registration scopes | Press Enter |
| CLI default client Region | `eu-west-1` (or wherever you want lab resources — **independent of SSO region**) |
| CLI default output format | `json` |
| CLI profile name | `k8s-dr-eu` |

Verify:

```bash
aws configure list-profiles          # → k8s-dr-eu
aws sso login --profile k8s-dr-eu
aws sts get-caller-identity --profile k8s-dr-eu
```

The last command prints your account ID, user ID, and ARN. If it works, you're authenticated.

### 3. Create `.env` from the template

```bash
cp .env.example .env
```

You'll fill in the Kasten credentials after step 5. For now, leave `K10_AWS_ACCESS_KEY_ID` and `K10_AWS_SECRET_ACCESS_KEY` blank.

### 4. Create Kind clusters + AWS resources

```bash
make cluster              # creates k8s-source + k8s-restore
make terraform-apply      # creates S3, SQS, Lambda, IAM role; writes .tf-output.json
```

After this, `.tf-output.json` exists and contains the bucket name, ARN, and queue URL.

### 5. Create the Kasten IAM user (CLI)

Kasten runs inside the cluster and needs long-lived static credentials for S3

```bash
PROFILE=k8s-dr-eu
USER=kasten-s3-backup
POLICY=kasten-s3-access
BUCKET_ARN=$(jq -r '.bucket_arn.value' .tf-output.json)

# 1. Create the user (skip if it already exists)
aws iam create-user --user-name "$USER" --profile "$PROFILE"

# 2. Write the S3 policy to a temp file
cat > /tmp/kasten-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:ListBucket", "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
    ],
    "Resource": [
      "${BUCKET_ARN}",
      "${BUCKET_ARN}/*"
    ]
  }]
}
EOF

```
Both `Resource` lines are required — the bare ARN covers bucket-level actions
(`ListBucket`), and the `/*` version covers object-level actions (`GetObject`,
`PutObject`).
```

# 3. Attach it
aws iam put-user-policy \
  --user-name "$USER" \
  --policy-name "$POLICY" \
  --policy-document file:///tmp/kasten-policy.json \
  --profile "$PROFILE"

# 4. Create the access key and save it
aws iam create-access-key --user-name "$USER" --profile "$PROFILE" \
  > /tmp/kasten-key.json

# 5. Write keys into .env (no quotes)
sed -i "s|^K10_AWS_ACCESS_KEY_ID=.*|K10_AWS_ACCESS_KEY_ID=$(jq -r .AccessKey.AccessKeyId /tmp/kasten-key.json)|" .env
sed -i "s|^K10_AWS_SECRET_ACCESS_KEY=.*|K10_AWS_SECRET_ACCESS_KEY=$(jq -r .AccessKey.SecretAccessKey /tmp/kasten-key.json)|" .env

# 6. Clean up
shred -u /tmp/kasten-key.json /tmp/kasten-policy.json 2>/dev/null || rm -f /tmp/kasten-key.json /tmp/kasten-policy.json

# 7. Verify
grep -E '^K10_AWS_' .env | sed 's/=.*/=<set>/'
```

Expected output:

```
K10_AWS_ACCESS_KEY_ID=<set>
K10_AWS_SECRET_ACCESS_KEY=<set>

```
6. Copy both values into `.env`:

   ```bash
   K10_AWS_ACCESS_KEY_ID=AKIA...
   K10_AWS_SECRET_ACCESS_KEY=...
   ```

### 6. Install Kasten + wire up S3

```bash
make bootstrap            # CSI snapshot driver + VolumeSnapshotClass on both clusters
make deploy-kasten        # K10 + S3 Location Profile on both clusters
```

### 7. Seed MongoDB with known data

```bash
kubectl --context kind-k8s-source -n mongodb exec mongodb-0 -- \
  mongosh --quiet -u root -p labpassword --authenticationDatabase admin \
  --eval 'db.getSiblingDB("testdb").users.insertMany(
    Array.from({length: 1000}, (_, i) => ({ _id: i, name: "user" + i }))
  )'
```

This inserts 1000 documents so `validate-backup.sh` has a known count to assert against.

### 8. Run the DR test

```bash
make backup               # snapshot + export to S3
make restore              # import from S3 + restore on cluster B
make validate-backup      # CR statuses + doc count == 1000
```

Expected output:

```
✅ Validation passed (backup + restore + 1000 docs)
```

### 9. Prove the one-liner from scratch

```bash
make down                 # delete both Kind clusters
make e2e                  # full flow, one command
```

Expected final output:

```
✅ E2E complete — backup, restore, and validation all passed.
```

## Day-to-day usage

Once setup is complete, you don't re-run the whole flow. Typical commands:

```bash
make help              # list all targets
make backup            # trigger an immediate backup
make restore           # restore from the latest restore point
make validate-backup   # run the 4 validation checks
make down              # delete both Kind clusters
make clean             # delete clusters + local artifacts
```

Each session, you need to re-authenticate SSO (tokens expire after ~8h):

```bash
aws sso login --profile k8s-dr-eu
```

## Fast AWS-pipeline test (no Kasten needed)

Prove the S3 → SQS → Lambda pipeline works without waiting for a Kasten backup:

```bash
make test-lambda         # upload a 10 KB object → expect OK in Lambda logs
make test-lambda-fail    # upload a 2-byte object → expect FAIL
```

Watch the Lambda:

```bash
aws logs tail /aws/lambda/k8s-dr-backup-validator --follow \
  --profile k8s-dr-eu --region eu-west-1
```

## Repository layout

```
Makefile                    Single entry point
scripts/                    bootstrap-clusters, deploy-kasten, restore, validate
terraform/                  S3 bucket, SQS queue, Lambda, IAM
lambda/handler.py           S3-event validator
manifests/
  kind-cluster-config.yaml  Shared Kind config for both clusters
  mongodb/                  StatefulSet, Service, Secret
  kasten/                   Helm values, Location Profile, Policy, RestoreAction
.env.example                Template for local env 
```

## How validation works

Two independent layers, each answering a different question:

| Layer | Where | Checks | Trigger |
|---|---|---|---|
| **AWS-side** | Lambda in AWS | S3 object exists, size ≥ `MIN_SIZE_BYTES` | Automatic on S3 `ObjectCreated` |
| **Cluster-side** | `scripts/validate-backup.sh` | Kasten CR status + MongoDB doc count | Manual via `make validate-backup` |

The Lambda can't reach the Kind cluster (no network path from AWS to your local machine), so the two layers run separately. Together they cover:

- Backup reached S3 ✅
- Backup isn't empty ✅
- Kasten thinks the backup/restore succeeded ✅
- The restored data actually has the expected number of documents ✅