# =============================================================================
# Makefile — genome-vault
# =============================================================================
# Standard developer targets. Run `make help` to list them.

.PHONY: help setup install lint lint-fix typecheck test test-unit test-integration \
        clean tf-init tf-plan tf-apply tf-destroy tf-fmt bq-bootstrap

# Default goal is help
.DEFAULT_GOAL := help

PYTHON       := .venv/bin/python
PIP          := .venv/bin/pip
VENV         := .venv
TF_DIR       := infra/terraform/environments/dev

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
help:  ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
setup: $(VENV)/bin/activate  ## Create venv and install all deps + pre-commit hooks.
	$(PIP) install --upgrade pip setuptools wheel
	$(PIP) install -e ".[dev,api]"
	$(VENV)/bin/pre-commit install
	@echo ""
	@echo "Setup complete. Activate with: source .venv/bin/activate"

$(VENV)/bin/activate:
	python3.12 -m venv $(VENV)

install:  ## Reinstall the project in editable mode (run after adding new packages).
	$(PIP) install -e ".[dev,api]"

# -----------------------------------------------------------------------------
# Lint, format, typecheck
# -----------------------------------------------------------------------------
lint:  ## Run ruff in check mode.
	$(VENV)/bin/ruff check src tests scripts

lint-fix:  ## Run ruff in fix mode + format.
	$(VENV)/bin/ruff check --fix src tests scripts
	$(VENV)/bin/ruff format src tests scripts

typecheck:  ## Run mypy in strict mode.
	$(VENV)/bin/mypy src tests

# -----------------------------------------------------------------------------
# Test
# -----------------------------------------------------------------------------
test: test-unit  ## Alias for test-unit (the default test target).

test-unit:  ## Run unit tests only (no coverage gate — fast iteration).
	@$(VENV)/bin/pytest -m unit --no-cov; \
	EC=$$?; \
	if [ $$EC -eq 5 ]; then \
	  echo "(no tests collected yet — treated as success)"; \
	  exit 0; \
	else \
	  exit $$EC; \
	fi

test-cov:  ## Run unit tests with coverage gate (used in CI).
	$(VENV)/bin/pytest -m unit

test-integration:  ## Run integration tests (requires GCP credentials).
	$(VENV)/bin/pytest -m integration

# -----------------------------------------------------------------------------
# Terraform
# -----------------------------------------------------------------------------
tf-init:  ## terraform init in dev environment.
	cd $(TF_DIR) && terraform init

tf-plan:  ## terraform plan in dev.
	cd $(TF_DIR) && terraform plan

tf-apply:  ## terraform apply in dev (will ask for confirmation).
	cd $(TF_DIR) && terraform apply

tf-destroy:  ## terraform destroy in dev (will ask for confirmation).
	cd $(TF_DIR) && terraform destroy

tf-fmt:  ## terraform fmt all infra dirs.
	cd infra/terraform && terraform fmt -recursive

# -----------------------------------------------------------------------------
# Bootstrap GCP state backend (one-time, before first tf-init)
# -----------------------------------------------------------------------------
bq-bootstrap:  ## One-time: create GCP project + GCS state bucket. Run before tf-init.
	bash scripts/bootstrap-gcp.sh

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------
clean:  ## Remove build artefacts, caches, coverage files.
	rm -rf build dist *.egg-info
	rm -rf .pytest_cache .mypy_cache .ruff_cache htmlcov .coverage coverage.xml
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
