# =============================================================================
# Makefile — genome-vault
# =============================================================================
# Standard developer targets. Run `make help` to list them.

.PHONY: help setup install lint lint-fix typecheck test test-unit test-integration \
        clean tf-init tf-plan tf-apply tf-destroy tf-fmt bq-bootstrap \
        fetch load-slice warehouse-local slice load-bq warehouse-bq

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
setup: $(VENV)/bin/activate  ## Create venv and install dev deps.
	$(PIP) install --upgrade pip setuptools wheel
	$(PIP) install -e ".[dev]"
	@echo ""
	@echo "Setup complete. Activate with: source .venv/bin/activate"

$(VENV)/bin/activate:
	python3.12 -m venv $(VENV)

install:  ## Reinstall the project in editable mode (run after adding new packages).
	$(PIP) install -e ".[dev]"

# -----------------------------------------------------------------------------
# Lint, format, typecheck
# -----------------------------------------------------------------------------
lint:  ## Run ruff in check mode.
	$(VENV)/bin/ruff check --select E,F,W,B,UP,I --ignore E501 src tests scripts

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
# Data and warehouse
# -----------------------------------------------------------------------------
SLICE        := tests/fixtures/real
PARQUET      := data/work/parquet
DUCKDB       := data/work/genome_vault.duckdb

fetch:  ## Download the real public sources (needs normal internet access).
	$(PYTHON) scripts/fetch_sources.py

load-slice:  ## Load the committed real slice (CYP2D6 region, 3,202 samples) into Parquet.
	$(PYTHON) -m genome_vault.cli load \
	  --kgp-vcf $(SLICE)/kgp_chr22_42050k_42250k.vcf.gz \
	  --clinvar $(SLICE)/clinvar_22_42050k_42250k.vcf.gz \
	  --genes $(SLICE)/ensembl_genes_22_42050k_42250k.gff3.gz \
	  --samples $(SLICE)/20130606_g1k_3202_samples_ped_population.txt \
	  --unrelated-panel $(SLICE)/integrated_call_samples_v3.20130502.ALL.panel \
	  --reference $(SLICE)/grch38_chr22_42050k_42250k.fa \
	  --out $(PARQUET)
	$(PYTHON) -m genome_vault.cli regions \
	  --bed segdup=$(SLICE)/giab_segdup_22_42050k_42250k.bed.gz \
	  --bed low_mappability=$(SLICE)/giab_low_mappability_22_42050k_42250k.bed.gz \
	  --bed tandem_repeat_homopolymer=$(SLICE)/giab_tandem_repeat_homopolymer_22_42050k_42250k.bed.gz \
	  --bed all_difficult=$(SLICE)/giab_all_difficult_22_42050k_42250k.bed.gz \
	  --out $(PARQUET)

warehouse-local:  ## Build and test the dbt warehouse on DuckDB from the loaded Parquet.
	cd warehouse && DBT_PROFILES_DIR=. GV_PARQUET=$(CURDIR)/$(PARQUET) GV_DUCKDB=$(CURDIR)/$(DUCKDB) \
	  GV_GNOMAD_CSV=$(CURDIR)/$(SLICE)/gnomad_v3_chr22_42049000_42251000.csv \
	  $(CURDIR)/$(VENV)/bin/dbt build --target local

slice: load-slice warehouse-local  ## Load the real slice and build the warehouse end to end.

load-bq:  ## Load full chr22 and load it into BigQuery gv_raw (needs terraform apply).
	bash scripts/load_bigquery.sh

warehouse-bq:  ## dbt build on BigQuery, then write docs/evidence/bigquery_full_chr22.*
	bash scripts/build_bigquery.sh

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
