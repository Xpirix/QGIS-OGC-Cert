# QGIS-OGC-Cert — OGC compliance harness for QGIS Server.
# See README.md. Override the image under test with: QGIS_TAG=stable make all

.PHONY: help bootstrap up down wms130 ogcapif all reports logs clean

help: ## Show this help
	@grep -hE '^[a-z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;34m%-10s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Fetch all test data (run once)
	@./scripts/bootstrap.sh

up: ## Start QGIS Server + nginx
	@docker compose up -d qgis-server nginx

down: ## Stop and remove the stack
	@docker compose --profile tools down --remove-orphans
	@docker rm -f pyogctest 2>/dev/null || true

wms130: ## Run the WMS 1.3.0 suite
	@./scripts/run-suite.sh wms130

ogcapif: ## Run the OGC API Features 1.0 suite
	@./scripts/run-suite.sh ogcapif

all: ## Run both suites
	@./scripts/run-suite.sh all

reports: ## List generated reports
	@find reports -type f 2>/dev/null | sort || echo "No reports yet — run 'make all'."

logs: ## Tail QGIS Server logs
	@docker compose logs -f qgis-server

clean: ## Remove the stack, test data and reports
	@docker compose --profile tools down -v --remove-orphans 2>/dev/null || true
	@docker rm -f pyogctest 2>/dev/null || true
	@rm -rf data reports
	@echo "Clean. Run 'make bootstrap' to start over."
