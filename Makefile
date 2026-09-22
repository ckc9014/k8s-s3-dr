# =========================================================
# k8s-s3-dr — DR lab: Kind + MongoDB + Kasten K10 + AWS S3
# =========================================================
# Once per session(What You Must Do Before):
# aws sso login
# =========================================================
# make help              # list all targets
# make cluster           # create both Kind clusters
# make bootstrap         # install CSI snapshot stack
# make terraform-apply   # create S3 + SQS + Lambda, write .tf-output.json
# make deploy-kasten     # install K10 + S3 profile on both clusters
# make backup            # trigger an immediate backup
# make restore           # restore from the latest restore point
# make validate-backup   # run the 4 validation checks
# make e2e               # full flow, one command
# make clean             # delete clusters + local artifacts
# make test-lambda       # prove the AWS pipeline without Kasten
# =========================================================
# Quick start:
#   cp .env.example .env   # fill in K10_AWS_* keys
#   make e2e
# =========================================================

SHELL := /usr/bin/env bash

# ---- config (override via .env or CLI) ------------------------------------
CLUSTERS         ?= k8s-source k8s-restore
CONFIG_PATH      ?= manifests/kind-cluster-config.yaml
APP_NAMESPACE    ?= mongodb
EXPECTED_DOCS    ?= 1000
TF_DIR            = terraform
SCRIPTS           = scripts

# ---- load .env (if present) ----------------------------------------------
ifneq (,$(wildcard ./.env))
include .env
export
endif

# ---- pretty help ----------------------------------------------------------
.DEFAULT_GOAL := help

.PHONY: help \
        cluster down list \
        bootstrap \
        terraform-init terraform-plan terraform-apply \
        deploy-kasten \
        backup restore validate-backup \
        e2e clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Cluster

cluster: ## Create both Kind clusters
	@for c in $(CLUSTERS); do \
	  if kind get clusters | grep -qx "$$c"; then \
	    echo "$$c already exists — skipping"; \
	  else \
	    echo "Creating Kind cluster '$$c'..."; \
	    kind create cluster --name $$c --config $(CONFIG_PATH); \
	  fi; \
	done

down: ## Delete both Kind clusters
	@for c in $(CLUSTERS); do \
	  if kind get clusters | grep -qx "$$c"; then \
	    echo "Deleting Kind cluster '$$c'..."; \
	    kind delete cluster --name $$c; \
	  else \
	    echo "$$c not found — skipping"; \
	  fi; \
	done

list: ## List Kind clusters
	@kind get clusters

##@ Bootstrap

bootstrap: ## Install CSI snapshot stack + VolumeSnapshotClass on both clusters
	$(SCRIPTS)/bootstrap-cluster.sh $(CLUSTERS)

##@ Terraform (AWS S3 + SQS + Lambda)

terraform-init: ## Initialize Terraform
	cd $(TF_DIR) && terraform init

terraform-plan: ## Show Terraform plan
	cd $(TF_DIR) && terraform plan

terraform-apply: ## Apply Terraform and capture outputs
	cd $(TF_DIR) && terraform apply -auto-approve
	cd $(TF_DIR) && terraform output -json > ../.tf-output.json
	@echo "Outputs written to .tf-output.json"

##@ Kasten

deploy-kasten: terraform-apply bootstrap ## Install Kasten K10 + S3 profile
	$(SCRIPTS)/deploy-kasten.sh $(CLUSTERS)

##@ DR flow

backup: ## Trigger an immediate Kasten backup on the source cluster
	@echo "Triggering backup via policy annotation..."
	@kubectl --context kind-$(firstword $(CLUSTERS)) -n kasten-io \
	  annotate policy mongodb-backup k10.kasten.io/run-now=true --overwrite
	@echo "Waiting for BackupAction to complete..."
	@bash -c 'for i in $$(seq 1 60); do \
	  latest=$$(kubectl --context kind-$(firstword $(CLUSTERS)) -n kasten-io get backupactions \
	    --sort-by=.metadata.creationTimestamp -o jsonpath="{.items[-1].metadata.name}" 2>/dev/null || true); \
	  if [ -n "$$latest" ]; then \
	    phase=$$(kubectl --context kind-$(firstword $(CLUSTERS)) -n kasten-io get backupaction $$latest \
	      -o jsonpath="{.status.phase}" 2>/dev/null || true); \
	    echo "  BackupAction $$latest: $$phase"; \
	    case "$$phase" in Complete) exit 0 ;; Failed|Aborted) exit 1 ;; esac; \
	  fi; \
	  sleep 5; \
	done; echo "timed out"; exit 1'

restore: ## Trigger a Kasten restore on the restore cluster
	@echo "Triggering restore..."
	@$(SCRIPTS)/restore.sh

validate-backup: ## Validate latest backup + restore + data (usage: make validate-backup EXPECTED_DOCS=1000)
	$(SCRIPTS)/validate-backup.sh $(APP_NAMESPACE) $(EXPECTED_DOCS)

##@ Orchestration

e2e: cluster terraform-apply bootstrap deploy-kasten backup restore validate-backup ## Full end-to-end flow
	@echo ""
	@echo "✅ E2E complete — backup, restore, and validation all passed."

##@ Cleanup

clean: down ## Delete clusters and remove local artifacts
	rm -rf $(TF_DIR)/.build
	rm -f .tf-output.json
	@echo "Local artifacts removed. (S3 bucket must be deleted manually.)"

##@ AWS helpers

test-lambda: ## Upload a dummy object to trigger the Lambda validation pipeline
	@head -c 10240 /dev/urandom > /tmp/dummy-backup.tar.gz
	@aws s3 cp /tmp/dummy-backup.tar.gz \
	  s3://$$(jq -r '.bucket_name.value' .tf-output.json)/k10/test/backup-$$(date +%s).tar.gz \
	  --profile $${AWS_PROFILE:-default} --region $${AWS_REGION:-eu-west-1}
	@echo "Uploaded. Watch logs with:"
	@echo "  aws logs tail /aws/lambda/$$(jq -r '.lambda_function_name.value' .tf-output.json) --follow"

test-lambda-fail: ## Upload a tiny object to test the failure path
	@echo "x" > /tmp/tiny.tar.gz
	@aws s3 cp /tmp/tiny.tar.gz \
	  s3://$$(jq -r '.bucket_name.value' .tf-output.json)/k10/test/tiny-$$(date +%s).tar.gz \
	  --profile $${AWS_PROFILE:-default} --region $${AWS_REGION:-eu-west-1}
	@echo "Uploaded (2 bytes) — expect FAIL in Lambda logs."