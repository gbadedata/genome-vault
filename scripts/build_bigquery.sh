#!/usr/bin/env bash
# =============================================================================
# scripts/build_bigquery.sh — dbt build on BigQuery, then write the evidence
# =============================================================================
# Runs every model and test against <project>.gv_raw (from load_bigquery.sh)
# and the public gnomAD v3 table, with the profile's 20 GB cap on any single
# query. Then records what happened in docs/evidence/, whether dbt passed or
# failed: test results, the QC summary, table sizes and the bytes billed.
#
# The evidence goes to data/work/evidence/ (not tracked by git), so a run
# never leaves local changes that block the next git pull. Committed snapshots
# live in docs/evidence/.
#
# Usage: bash scripts/build_bigquery.sh
# =============================================================================
set -euo pipefail

# GV_PROJECT_ID, not GCP_PROJECT_ID: other projects on the same machine set
# that one, and it silently pointed these scripts at the wrong project.
PROJECT="${GV_PROJECT_ID:-genome-vault-202605}"
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Refuse to run stale code: a pull that failed earlier once left the old code
# in place and the run silently used it. GV_ALLOW_STALE=1 skips the check.
if git rev-parse --git-dir >/dev/null 2>&1; then
  CODE_VERSION="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- src warehouse scripts || echo '+local-changes')"
  if [[ "${GV_ALLOW_STALE:-0}" != "1" ]] && git fetch -q origin main 2>/dev/null; then
    behind=$(git rev-list --count HEAD..origin/main)
    [[ "$behind" == "0" ]] || { echo "STOP: this copy is $behind commit(s) behind GitHub: run git pull first" >&2; exit 1; }
  fi
else
  CODE_VERSION="unknown"
fi
echo "== Code version $CODE_VERSION"

command -v dbt >/dev/null || { echo "STOP: dbt not on PATH (pip install -e \".[cloud]\")" >&2; exit 1; }
python -c "import dbt.adapters.bigquery, google.cloud.bigquery" 2>/dev/null \
  || { echo "STOP: dbt-bigquery is not installed in this Python (pip install -e \".[cloud]\")" >&2; exit 1; }
[[ -f data/work/full/bq_load.json ]] || { echo "STOP: no data/work/full/bq_load.json: run bash scripts/load_bigquery.sh first" >&2; exit 1; }
echo "== Project $PROJECT"

export GV_PROJECT_ID="$PROJECT"
export DBT_PROFILES_DIR="$ROOT/warehouse"
# dbt-core 1.12 bundles the dbt State plugin (a dbt Labs cloud service that
# needs an account and sends run metadata off the machine). It is opt-in, but
# a user_settings.yml left by another dbt version can switch it on, and then
# the build stops to ask for a browser login. This project never uses it.
export DBT_ENGINE_MANAGE_STATE=false
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
  --code-version "$CODE_VERSION" \
  --out data/work/evidence

if [[ $status -ne 0 ]]; then
  echo "dbt build failed (exit $status); the evidence above shows which nodes." >&2
fi
exit $status
