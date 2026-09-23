# =========================================================
# k8s-s3-dr — DR lab: Kind + MongoDB + Kasten K10 + AWS S3
# =========================================================
# Once per session (What You Must Do Before):
#   aws sso login --profile k8s-dr-eu
# =========================================================
# Quick start (fresh clone):
#   cp .env.example .env       # leave K10_AWS_* blank — filled automatically
#   aws sso login              # per session
#   make e2e
# =========================================================
# IAM setup runs automatically as part of `deploy-kasten`.
# To run it manually: make iam-setup
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
        iam-setup vendor-crds \
        deploy-mongo deploy-kasten \
        backup restore validate-backup \
        e2e clean \
        test-lambda test-lambda-fail

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
	$(SCRIPTS)/bootstrap-clusters.sh $(CLUSTERS)

##@ Terraform (AWS S3 + SQS + Lambda)

terraform-init: ## Initialize Terraform (safe to re-run)
	cd $(TF_DIR) && terraform init -upgrade

terraform-plan: terraform-init ## Show Terraform plan
	cd $(TF_DIR) && terraform plan

terraform-apply: terraform-init ## Apply Terraform and capture outputs
	cd $(TF_DIR) && terraform apply -auto-approve
	cd $(TF_DIR) && terraform output -json > ../.tf-output.json
	@echo "Outputs written to .tf-output.json"

##@ Kasten setup helpers

iam-setup: terraform-apply ## One-time: create Kasten IAM user, attach policy, write keys to .env
	@if [ ! -f $(SCRIPTS)/setup-iam-user.sh ]; then \
	  echo "ERROR: $(SCRIPTS)/setup-iam-user.sh not found."; \
	  echo "       See README step 5, or create the script."; \
	  exit 1; \
	fi
	$(SCRIPTS)/setup-iam-user.sh

vendor-crds: ## Dump Kasten CRDs from source cluster into manifests/kasten/crds/
	@mkdir -p manifests/kasten/crds
	@echo "Dumping Kasten CRDs from kind-$(firstword $(CLUSTERS))..."
	@kubectl --context kind-$(firstword $(CLUSTERS)) get crd -o name \
	  | grep 'kio.kasten.io' \
	  | while read -r crd; do \
	      name="$${crd#customresourcedefinition.apiextensions.k8s.io/}"; \
	      echo "  -> $${name}.yaml"; \
	      kubectl --context kind-$(firstword $(CLUSTERS)) get "$$crd" -o json \
	        | jq 'del( \
	            .metadata.uid, \
	            .metadata.resourceVersion, \
	            .metadata.generation, \
	            .metadata.creationTimestamp, \
	            .metadata.managedFields, \
	            .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"], \
	            .status \
	          )' > "manifests/kasten/crds/$${name}.yaml"; \
	    done
	@echo ""
	@echo "Done. Commit these with:"
	@echo "  git add manifests/kasten/crds/ && git commit -m 'feat(kasten): vendor CRDs'"

##@ Workload

deploy-mongo: ## Apply MongoDB manifests to the SOURCE cluster only
	@echo "Applying MongoDB to kind-$(firstword $(CLUSTERS))..."
	kubectl --context kind-$(firstword $(CLUSTERS)) apply -f manifests/mongodb/
	@echo "Waiting for mongodb-0 to be Ready..."
	kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) \
	  wait --for=condition=Ready pod/mongodb-0 --timeout=180s
	@echo "✅ MongoDB ready on kind-$(firstword $(CLUSTERS))"

seed-mongo: ## Insert EXPECTED_DOCS test documents into MongoDB (source cluster)
	@echo "Seeding $(EXPECTED_DOCS) documents into testdb.users..."
	@kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) exec mongodb-0 -- \
	  mongosh --quiet -u root -p labpassword --authenticationDatabase admin \
	  --eval "db.getSiblingDB('testdb').users.insertMany( \
	    Array.from({length: $(EXPECTED_DOCS)}, (_, i) => ({ _id: i, name: 'user' + i })) \
	  )"
	@echo "✅ Seeded $(EXPECTED_DOCS) documents"

##@ Kasten

deploy-kasten: terraform-apply bootstrap iam-setup ## Install Kasten K10 + S3 profile (auto-runs IAM setup)
	$(SCRIPTS)/deploy-kasten.sh $(CLUSTERS)

##@ DR flow

backup: ## Trigger an immediate Kasten backup on the source cluster
	@echo "Triggering backup via RunAction..."
	@NAME="manual-run-$$(date +%s)"; \
	  sed "s/REPLACE_ME/$${NAME}/" manifests/kasten/run-action.yaml \
	    | kubectl --context kind-$(firstword $(CLUSTERS)) create -f -
	@echo "Waiting for BackupAction to complete..."
	@bash -c 'for i in $$(seq 1 120); do \
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

validate-backup: ## Validate latest backup + restore + data
	$(SCRIPTS)/validate-backup.sh $(APP_NAMESPACE) $(EXPECTED_DOCS)

##@ Orchestration

e2e: cluster terraform-apply bootstrap deploy-kasten deploy-mongo seed-mongo backup restore validate-backup ## Full end-to-end flow
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