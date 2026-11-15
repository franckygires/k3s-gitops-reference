# Every target is a thin wrapper around a script in scripts/, so each step can be read on its own.
.DEFAULT_GOAL := help
.PHONY: help tools up sync status diagnose test drill rebuild ui destroy

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[1m%-9s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Install the pinned k3d into ./bin (checksum verified)
	@scripts/tools.sh

up: ## Create the cluster and let Argo CD deploy everything from Git
	@scripts/up.sh

sync: ## Publish the current working tree to the local Git mirror; Argo CD applies it within 30 s
	@scripts/mirror.sh >/dev/null && echo "Published. Argo CD will pick it up within 30 seconds."

status: ## Show nodes, Argo CD applications and anything not running
	@scripts/status.sh

diagnose: ## Print what is needed to understand a failure
	@scripts/diagnose.sh

test: ## Check the running cluster against what the README claims
	@scripts/test.sh

drill: ## Stop the node hosting the PostgreSQL primary and prove no acknowledged write is lost
	@scripts/drill.sh

rebuild: ## Destroy, rebuild from Git, verify, and report the total time
	@scripts/rebuild.sh

ui: ## Open the Argo CD UI on http://localhost:8081
	@scripts/ui.sh

destroy: ## Delete the cluster and the local Git mirror
	@scripts/destroy.sh
