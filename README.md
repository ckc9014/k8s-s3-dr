# k8s-s3-dr

Cross-cluster disaster recovery lab: two Kind clusters running MongoDB,
backed up by Kasten K10 to AWS S3, validated end to end.

## What it does

- Two Kind clusters: `dr-lab-source` (backs up) and `dr-lab-restore` (restores)
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
│  CSI hostpath + VSC    │         │  CSI hostpath + VSC    │
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

## Prerequisites

- **WSL2** (Ubuntu) on Windows, or native Linux
- **Docker Desktop** with WSL integration enabled (8 GB+ RAM recommended)
- **AWS account** with:
  - IAM Identity Center (SSO) access configured
  - Permission to create S3 buckets, SQS queues, Lambda functions, IAM roles
- **Tools installed in WSL:**
  - `kind` v0.24+
  - `kubectl` v1.28+
  - `helm` v3.12+
  - `terraform` v1.5+
  - `aws` CLI v2 (required for `aws configure sso`)
  - `jq`
  - `envsubst` (part of `gettext`)

Quick install check:

```bash
for t in kind kubectl helm terraform aws jq envsubst make; do
  command -v "$t" >/dev/null && echo "OK: $t" || echo "MISSING: $t"
done
```

## Setup

### 1. Clone and configure AWS SSO

```bash
git clone https://github.com/ckc9014/k8s-s3-dr.git

aws configure sso
# SSO session name:   my-sso
# SSO start URL:      <your org's portal URL>
# SSO region:         Where IAM Identity Center is configured
# CLI default region: eu-west-1
# Profile name:       k8s-dr-eu
```

Verify:

```bash
aws configure list-profiles         
aws sso login --profile k8s-dr-eu
aws sts get-caller-identity --profile k8s-dr-eu
```

### 2. Copy `.env.example` and fill in the Kasten keys

```bash
cp .env.example .env
nano .env
```

Set `K10_AWS_ACCESS_KEY_ID` and `K10_AWS_SECRET_ACCESS_KEY` from a
**dedicated IAM user** scoped to the backup bucket (see step 4).

### 3. Create the S3 bucket first

```bash
make cluster
make terraform-apply
```

This creates the bucket, SQS queue, Lambda, and writes `.tf-output.json`.

### 4. Create the Kasten IAM user

In the AWS Console:

1. **IAM → Users → Create user** named `kasten-s3-backup`
2. **No console access** (programmatic only)
3. Attach policies (s3)
4. **Security credentials → Create access key**
5. Copy both keys into `.env`

## Usage

```bash
make help              # list all targets
make cluster           # create both Kind clusters
make bootstrap         # install CSI snapshot stack on both
make terraform-apply   # create S3 + SQS + Lambda, write .tf-output.json
make deploy-kasten     # install K10 + S3 profile on both clusters
make backup            # trigger an immediate backup
make restore           # restore from the latest restore point
make validate-backup   # run the 4 validation checks
make e2e               # full flow, one command
make clean             # delete clusters + local artifacts
```

### Fast AWS-pipeline test (no Kasten needed)

```bash
make test-lambda         # upload a 10 KB object → expect OK in Lambda logs
make test-lambda-fail    # upload a 2-byte object → expect FAIL
```

Watch the Lambda:

```bash
aws logs tail /aws/lambda/k8s-dr-backup-validator --follow \
  --profile k8s-dr-eu --region eu-west-1
```

### Full end-to-end run (include restore)

```bash
aws sso login --profile k8s-dr-eu
make e2e
```

Expected final output:

```
✅ E2E complete — backup, restore, and validation all passed.
```

## Repository layout

```
Makefile                    Single entry point
scripts/                    bootstrap, deploy-kasten, backup triggers, validate
terraform/                  S3 bucket, SQS queue, Lambda, IAM
lambda/handler.py           S3-event validator
manifests/
  kind-cluster-config.yaml  Shared Kind config for both clusters
  mongodb/                  StatefulSet, Service, Secret
  kasten/                   Helm values, Location Profile, Policy, RestoreAction
.env.example                Template for local env (commit; .env stays local)
```

## How validation works

Two independent layers, each answering a different question:

| Layer | Where | Checks | Trigger |
|---|---|---|---|
| **AWS-side** | Lambda in AWS | S3 object exists, size ≥ `MIN_SIZE_BYTES` | Automatic on S3 `ObjectCreated` |
| **Cluster-side** | `scripts/validate-backup.sh` | Kasten CR status + MongoDB doc count | Manual via `make validate-backup` |

The Lambda can't reach the Kind cluster (no network path from AWS to WSL),
so the two layers run separately. Together they cover:

- Backup reached S3 ✅
- Backup isn't empty ✅
- Kasten thinks the backup/restore succeeded ✅
- The restored data actually has the expected number of documents ✅