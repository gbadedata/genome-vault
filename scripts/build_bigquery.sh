#!/usr/bin/env bash
# =============================================================================
# scripts/build_bigquery.sh — dbt build on BigQuery, then write the evidence
# =============================================================================
# Runs every model and test against <project>.gv_raw (from load_bigquery.sh)
# and the public gnomAD v3 table, with the profile's 20 GB cap on any single
# query. Then records what happened in docs/evidence/, whether dbt passed or
# failed: test results, the QC summary, table sizes and the bytes billed.
#
# Usage: bash scripts/build_bigquery.sh
# =============================================================================
set -euo pipefail

# GV_PROJECT_ID, not GCP_PROJECT_ID: other projects on the same machine set
# that one, and it silently pointed these scripts at the wrong project.
PROJECT="${GV_PROJECT_ID:-genome-vault-202605}"
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

command -v dbt >/dev/null || { echo "STOP: dbt not on PATH (pip install -e \".[cloud]\")" >&2; exit 1; }
python -c "import dbt.adapters.bigquery, google.cloud.bigquery" 2>/dev/null \
  || { echo "STOP: dbt-bigquery is not installed in this Python (pip install -e \".[cloud]\")" >&2; exit 1; }
[[ -f data/work/full/bq_load.json ]] || { echo "STOP: no data/work/full/bq_load.json: run bash scripts/load_bigquery.sh first" >&2; exit 1; }
echo "== Project $PROJECT"

export GV_PROJECT_ID="$PROJECT"
export DBT_PROFILES_DIR="$ROOT/warehouse"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "== dbt build on BigQuery (project $PROJECT)"
status=0
(cd warehouse && dbt build --target bigquery) || status=$?

echo
echo "== Writing evidence"
python scripts/bq_evidence.py \
  --project "$PROJECT" \
  --since "$started" \
  --run-results warehouse/target/run_results.json \
  --load-record data/work/full/bq_load.json \
  --out docs/evidence

if [[ $status -ne 0 ]]; then
  echo "dbt build failed (exit $status); the evidence above shows which nodes." >&2
fi
exit $status
