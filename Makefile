# =========================================================
# k8s-s3-dr — DR lab: Kind + MongoDB + Kasten K10 + AWS S3
# =========================================================
# Once per session: aws sso login --profile k8s-dr-eu
#
# Flow (read top to bottom):
#   1. Infrastructure  → clusters + AWS + CSI + Kasten
#   2. Source side     → MongoDB + backup → S3
#   3. Restore side    → import ← S3 + restore + validate
#
# Commands:
#   make e2e    → infra + source workload (ready to test)
#   make dr     → run the DR cycle (seed → backup → import → restore → validate)
# =========================================================

SHELL := /usr/bin/env bash

CLUSTERS         ?= k8s-source k8s-restore
CONFIG_PATH      ?= manifests/kind-cluster-config.yaml
APP_NAMESPACE    ?= mongodb
EXPECTED_DOCS    ?= 1000
TF_DIR            = terraform
SCRIPTS           = scripts

ifneq (,$(wildcard ./.env))
include .env
export
endif

.DEFAULT_GOAL := help

.PHONY: help \
        cluster down list \
        bootstrap \
        terraform-init terraform-plan terraform-apply \
        iam-setup vendor-crds \
        deploy-mongo seed-mongo \
        deploy-kasten \
        backup \
        import-restore-points restore validate-backup \
        e2e dr clean \
        test-lambda test-lambda-fail \
		reset-dr

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

# ===========================================================================
##@ 1. Infrastructure
# ===========================================================================

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

bootstrap: ## Install CSI snapshot stack on both clusters
	$(SCRIPTS)/bootstrap-clusters.sh $(CLUSTERS)

terraform-init: ## Initialize Terraform
	cd $(TF_DIR) && terraform init -upgrade

terraform-plan: terraform-init ## Show Terraform plan
	cd $(TF_DIR) && terraform plan

terraform-apply: terraform-init ## Create AWS S3 + SQS + Lambda; write .tf-output.json
	cd $(TF_DIR) && terraform apply -auto-approve
	cd $(TF_DIR) && terraform output -json > ../.tf-output.json
	@echo "Outputs written to .tf-output.json"

iam-setup: terraform-apply ## One-time: create Kasten IAM user, write keys to .env
	@if [ ! -f $(SCRIPTS)/setup-iam-user.sh ]; then \
	  echo "ERROR: $(SCRIPTS)/setup-iam-user.sh not found."; \
	  echo "       See README step 5, or create the script."; \
	  exit 1; \
	fi
	$(SCRIPTS)/setup-iam-user.sh

deploy-kasten: terraform-apply bootstrap iam-setup ## Install K10 on both clusters + profiles + policies
	$(SCRIPTS)/deploy-kasten.sh $(CLUSTERS)

vendor-crds: ## Dump Kasten CRDs from live cluster to manifests/kasten/crds/
	@mkdir -p manifests/kasten/crds
	@echo "Dumping CRDs from kind-$(firstword $(CLUSTERS))..."
	@kubectl --context kind-$(firstword $(CLUSTERS)) get crd -o name \
	  | grep 'kio.kasten.io' \
	  | while read -r crd; do \
	      name="$${crd#customresourcedefinition.apiextensions.k8s.io/}"; \
	      echo "  -> $${name}.yaml"; \
	      kubectl --context kind-$(firstword $(CLUSTERS)) get "$$crd" -o json \
	        | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"], .status)' \
	        > "manifests/kasten/crds/$${name}.yaml"; \
	    done
	@echo ""
	@echo "Now commit:"
	@echo "  git add manifests/kasten/crds/ && git commit -m 'feat(kasten): vendor CRDs'"

# ===========================================================================
##@ 2. Source side (backup → S3)
# ===========================================================================

deploy-mongo: ## Deploy MongoDB to SOURCE cluster
	@echo "[SOURCE] Applying MongoDB to kind-$(firstword $(CLUSTERS))..."
	kubectl --context kind-$(firstword $(CLUSTERS)) apply -f manifests/mongodb/
	kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) \
	  wait --for=condition=Ready pod/mongodb-0 --timeout=180s
	@echo "[SOURCE] ✅ MongoDB ready"

seed-mongo: ## Drop + re-seed EXPECTED_DOCS test docs (idempotent)
	@echo "[TEST] Seeding $(EXPECTED_DOCS) docs into testdb.users..."
	@kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) exec mongodb-0 -- \
	  mongosh --quiet -u root -p labpassword --authenticationDatabase admin \
	  --eval "db.getSiblingDB('testdb').users.drop(); \
	          db.getSiblingDB('testdb').users.insertMany( \
	            Array.from({length: $(EXPECTED_DOCS)}, (_, i) => ({ _id: i, name: 'user' + i })) \
	          ); \
	          print('inserted ' + db.getSiblingDB('testdb').users.countDocuments() + ' docs');"
	@echo "[TEST] ✅ Seeded $(EXPECTED_DOCS) docs (collection dropped first)"

backup: ## Source → snapshot + export to S3
	@echo "[SOURCE] Triggering backup via RunAction..."
	@kubectl --context kind-$(firstword $(CLUSTERS)) \
	  create -f manifests/kasten/run-action.yaml
	@echo "[SOURCE] Waiting for BackupAction + Export to S3..."
	@bash -c 'for i in $$(seq 1 180); do \
	  latest=$$(kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) get backupactions \
	    --sort-by=.metadata.creationTimestamp -o jsonpath="{.items[-1].metadata.name}" 2>/dev/null || true); \
	  if [ -n "$$latest" ]; then \
	    phase=$$(kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) get backupaction $$latest \
	      -o jsonpath="{.status.state}" 2>/dev/null || true); \
	    echo "  BackupAction $$latest: $$phase"; \
	    case "$$phase" in Complete) exit 0 ;; Failed|Aborted) exit 1 ;; esac; \
	  fi; \
	  sleep 5; \
	done; echo "timed out"; exit 1'

# ===========================================================================
##@ 3. Restore side (S3 → restore → validate)
# ===========================================================================

import-restore-points: ## S3 → import restore points into restore cluster
	@echo "[RESTORE] Refreshing migration token on import policy..."
	@SOURCE_CTX=kind-$(firstword $(CLUSTERS)) \
	 RESTORE_CTX=kind-$(lastword $(CLUSTERS)) \
	 K10_NAMESPACE=kasten-io \
	 $(SCRIPTS)/refresh-import-token.sh
	@echo ""
	@echo "[RESTORE] Triggering import via RunAction..."
	@kubectl --context kind-$(lastword $(CLUSTERS)) \
	  create -f manifests/kasten/import-run-action.yaml
	@echo "[RESTORE] Waiting for imported RestorePointContents..."
	@bash -c 'for i in $$(seq 1 60); do \
	  count=$$(kubectl --context kind-$(lastword $(CLUSTERS)) get restorepointcontents \
	    --no-headers 2>/dev/null | wc -l); \
	  if [ "$$count" -gt 0 ]; then \
	    echo "  found $$count imported contents"; exit 0; \
	  fi; \
	  echo "  waiting... ($$i/60)"; \
	  sleep 5; \
	done; echo "timed out waiting for RestorePointContents"; exit 1'
	@echo "[RESTORE] Linking RestorePointContents → RestorePoints"
	@RESTORE_CTX=kind-$(lastword $(CLUSTERS)) APP_NAMESPACE=$(APP_NAMESPACE) \
	  $(SCRIPTS)/link-restorepoints.sh

restore: ## Restore MongoDB into RESTORE cluster from latest restore point
	@echo "[RESTORE] Triggering RestoreAction..."
	@$(SCRIPTS)/restore.sh

validate-backup: ## Assert restored data matches EXPECTED_DOCS
	@echo "[VALIDATE] Checking backup status + restored doc count..."
	$(SCRIPTS)/validate-backup.sh $(APP_NAMESPACE) $(EXPECTED_DOCS)

# ===========================================================================
##@ Orchestration
# ===========================================================================

# Phase 1 — stand up infrastructure + source workload (MongoDB running, no data).
# Does NOT seed, backup, or restore. Just makes the environment ready.
e2e: cluster terraform-apply bootstrap deploy-kasten deploy-mongo
	@echo ""
	@echo "✅ Infrastructure + source workload ready."
	@echo ""
	@echo "Next:"
	@echo "  make dr              → full DR cycle (seed → backup → import → restore → validate)"
	@echo "  make seed-mongo      → just refresh test data"
	@echo "  make backup          → source only: snapshot + export to S3"

# Phase 2 — full DR cycle. Self-contained, re-runnable.
# Flow:
#   [TEST]     seed fresh 1000 docs (drop + insert)
#   [SOURCE]   snapshot + export to S3
#   [RESTORE]  import from S3 → restore → validate
dr: seed-mongo backup import-restore-points restore validate-backup
	@echo ""
	@echo "✅ DR cycle complete."
	@echo ""
	@echo "   [TEST]    fresh $(EXPECTED_DOCS) docs seeded"
	@echo "   [SOURCE]  snapshot + export to S3"
	@echo "   [RESTORE] import + restore + validate"

##@ Cleanup

clean: down ## Delete clusters + local artifacts
	rm -rf $(TF_DIR)/.build
	rm -f .tf-output.json
	@echo "Local artifacts removed. (S3 bucket must be deleted manually.)"

##@ DR reset

reset-dr: ## Wipe DR state (Kasten CRs + S3 for current cluster) — keeps infra
	@echo "[RESET] Removing Kasten DR CRs on both clusters..."
	@kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) \
	  delete backupactions,exportactions,restoreactions --all --ignore-not-found 2>/dev/null || true
	@kubectl --context kind-$(firstword $(CLUSTERS)) -n $(APP_NAMESPACE) \
	  delete restorepoints --all --ignore-not-found 2>/dev/null || true
	@kubectl --context kind-$(firstword $(CLUSTERS)) -n kasten-io \
	  delete runactions,importactions,exportactions --all --ignore-not-found 2>/dev/null || true
	@kubectl --context kind-$(lastword $(CLUSTERS)) \
	  delete restorepointcontents --all --ignore-not-found 2>/dev/null || true
	@kubectl --context kind-$(lastword $(CLUSTERS)) -n $(APP_NAMESPACE) \
	  delete restorepoints,restoreactions --all --ignore-not-found 2>/dev/null || true
	@kubectl --context kind-$(lastword $(CLUSTERS)) -n kasten-io \
	  delete runactions,importactions --all --ignore-not-found 2>/dev/null || true
	@echo "[RESET] Deleting any restored MongoDB on restore cluster..."
	@kubectl --context kind-$(lastword $(CLUSTERS)) -n $(APP_NAMESPACE) \
	  delete statefulset mongodb --ignore-not-found 2>/dev/null || true
	@kubectl --context kind-$(lastword $(CLUSTERS)) -n $(APP_NAMESPACE) \
	  delete pvc data-mongodb-0 --ignore-not-found 2>/dev/null || true
	@echo "[RESET] Wiping S3 data for current cluster..."
	@BUCKET=$$(jq -r '.bucket_name.value' .tf-output.json); \
	  for id in $$(aws s3 ls "s3://$$BUCKET/k10/" --profile $${AWS_PROFILE:-default} --region $${AWS_REGION:-eu-west-1} | awk '{print $$2}' | tr -d '/'); do \
	    echo "  removing k10/$$id/"; \
	    aws s3 rm "s3://$$BUCKET/k10/$$id/" --recursive \
	      --profile $${AWS_PROFILE:-default} --region $${AWS_REGION:-eu-west-1} >/dev/null; \
	  done
	@echo ""
	@echo "✅ DR state reset (infra + Kasten install untouched)."
	@echo "   Next: make dr"

##@ AWS helpers

test-lambda: ## Upload a dummy object to trigger the Lambda validation pipeline
	@head -c 10240 /dev/urandom > /tmp/dummy-backup.tar.gz
	@aws s3 cp /tmp/dummy-backup.tar.gz \
	  s3://$$(jq -r '.bucket_name.value' .tf-output.json)/k10/test/backup-$$(date +%s).tar.gz \
	  --profile $${AWS_PROFILE:-default} --region $${AWS_REGION:-eu-west-1}
	@echo "Uploaded. Watch with:"
	@echo "  aws logs tail /aws/lambda/$$(jq -r '.lambda_function_name.value' .tf-output.json) --follow"

test-lambda-fail: ## Upload a tiny object to test the failure path
	@echo "x" > /tmp/tiny.tar.gz
	@aws s3 cp /tmp/tiny.tar.gz \
	  s3://$$(jq -r '.bucket_name.value' .tf-output.json)/k10/test/tiny-$$(date +%s).tar.gz \
	  --profile $${AWS_PROFILE:-default} --region $${AWS_REGION:-eu-west-1}
	@echo "Uploaded (2 bytes) — expect FAIL in Lambda logs."