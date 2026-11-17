#!/usr/bin/env bash
# =============================================================================
# scripts/load_bigquery.sh — full chromosome 22 into BigQuery
# =============================================================================
# 1. Runs `genome-vault load` over the full sources in data/full/ (paths come
#    from data/sources/manifest.json, written by scripts/fetch_sources.py).
# 2. Uploads the Parquet to gs://<project>-gv-data/runs/<run_id>/.
# 3. Loads every table into <project>.gv_raw with `bq load --replace`.
# 4. Checks BigQuery row counts against the Parquet the loader wrote.
#
# Every gcloud and bq call names the project, so nothing is billed to whatever
# project gcloud happens to default to.
#
# Usage:  bash scripts/load_bigquery.sh               # load, upload, check
#         bash scripts/load_bigquery.sh --skip-loader # reuse existing Parquet
# Needs:  terraform apply done (bucket and datasets), gcloud auth login,
#         gcloud auth application-default login, pip install -e ".[cloud]".
# =============================================================================
set -euo pipefail

# GV_PROJECT_ID, not GCP_PROJECT_ID: other projects on the same machine set
# that one, and it silently pointed these scripts at the wrong project.
PROJECT="${GV_PROJECT_ID:-genome-vault-202605}"
LOCATION="US"
BUCKET="${GV_BUCKET:-${PROJECT}-gv-data}"
RAW_DATASET="${GV_RAW_DATASET:-gv_raw}"
WORK="${GV_WORK:-data/work/full}"
PARQUET="$WORK/parquet"
MANIFEST="data/sources/manifest.json"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SKIP_LOADER=0
[[ "${1:-}" == "--skip-loader" ]] && SKIP_LOADER=1

step() { printf '\n== %s\n' "$1"; }
fail() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

cd "$(dirname "$0")/.."

# -----------------------------------------------------------------------------
step "Pre-flight (project $PROJECT, location $LOCATION)"
for tool in gcloud bq python genome-vault; do
  command -v "$tool" >/dev/null || fail "$tool is not on PATH (activate the venv, then: pip install -e \".[cloud]\")"
done
python -c "import google.cloud.bigquery, pyarrow" 2>/dev/null || fail "google-cloud-bigquery missing: pip install -e \".[cloud]\""
[[ -f "$MANIFEST" ]] || fail "$MANIFEST is missing: run python scripts/fetch_sources.py first"
gcloud auth print-access-token >/dev/null 2>&1 || fail "gcloud is not signed in: gcloud auth login"
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || fail "no application-default credentials: gcloud auth application-default login"

ds_json=$(bq --project_id="$PROJECT" show --format=json "$PROJECT:$RAW_DATASET" 2>/dev/null) \
  || fail "dataset $PROJECT:$RAW_DATASET not found (is $PROJECT the right project? run terraform apply first)"
ds_location=$(python -c 'import json,sys; print(json.loads(sys.argv[1])["location"])' "$ds_json")
[[ "$ds_location" == "$LOCATION" ]] || fail "$RAW_DATASET is in $ds_location, expected $LOCATION"
bucket_location=$(gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT" --format='value(location)' 2>/dev/null) \
  || fail "bucket gs://$BUCKET not found: run terraform apply first"
[[ "$bucket_location" == "$LOCATION" ]] || fail "gs://$BUCKET is in $bucket_location, expected $LOCATION"
echo "  dataset $RAW_DATASET in $ds_location, bucket gs://$BUCKET in $bucket_location"

source_path() {
  python - "$MANIFEST" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["sources"][sys.argv[2]]["path"])
PY
}
KGP_VCF=$(source_path kgp_chr22_vcf)
CLINVAR=$(source_path clinvar_vcf)
GENES=$(source_path ensembl_gff3)
SAMPLES=$(source_path kgp_samples)
PANEL=$(source_path kgp_phase3_panel)
REFERENCE=$(source_path ucsc_chr22_fasta)
for f in "$KGP_VCF" "$CLINVAR" "$GENES" "$SAMPLES" "$PANEL" "$REFERENCE"; do
  [[ -f "$f" ]] || fail "$f is missing: rerun python scripts/fetch_sources.py"
done

# -----------------------------------------------------------------------------
if [[ $SKIP_LOADER -eq 0 ]]; then
  step "Loading full chr22 with genome-vault load (expect roughly 10 minutes)"
  rm -rf "$PARQUET"
  started=$(date +%s)
  genome-vault load \
    --kgp-vcf "$KGP_VCF" \
    --clinvar "$CLINVAR" \
    --genes "$GENES" \
    --samples "$SAMPLES" \
    --unrelated-panel "$PANEL" \
    --reference "$REFERENCE" \
    --contig chr22 \
    --out "$PARQUET" 2> >(grep -v "hts_idx_load3" >&2)
  echo "  loader finished in $(( $(date +%s) - started )) s"
else
  step "Reusing the Parquet in $PARQUET"
fi
[[ -f "$PARQUET/load_summary.json" ]] || fail "$PARQUET/load_summary.json is missing: run without --skip-loader"

# -----------------------------------------------------------------------------
step "Uploading Parquet to gs://$BUCKET/runs/$RUN_ID/"
gcloud storage cp --recursive --project="$PROJECT" "$PARQUET" "gs://$BUCKET/runs/$RUN_ID/"

# -----------------------------------------------------------------------------
step "Loading tables into $PROJECT:$RAW_DATASET"
for dir in "$PARQUET"/*/; do
  table=$(basename "$dir")
  extra=()
  # Genotypes are the big table; clustering keeps per-variant lookups cheap.
  [[ "$table" == "kgp_genotypes" ]] && extra=("--clustering_fields=variant_key,sample_index")
  echo "  $table"
  bq --quiet --project_id="$PROJECT" --location="$LOCATION" load --replace \
    --source_format=PARQUET ${extra[@]+"${extra[@]}"} \
    "$PROJECT:$RAW_DATASET.$table" "gs://$BUCKET/runs/$RUN_ID/parquet/$table/*.parquet"
done

# -----------------------------------------------------------------------------
step "Checking BigQuery row counts against the Parquet"
python - "$PROJECT" "$RAW_DATASET" "$PARQUET" "$RUN_ID" "gs://$BUCKET/runs/$RUN_ID/parquet" "$WORK/bq_load.json" <<'PY'
import datetime as dt
import json
import pathlib
import sys

import pyarrow.parquet as pq
from google.cloud import bigquery

project, dataset, parquet, run_id, gcs, out = sys.argv[1:7]
client = bigquery.Client(project=project, location="US")
tables, bad = {}, 0
for d in sorted(p for p in pathlib.Path(parquet).iterdir() if p.is_dir()):
    local = sum(pq.ParquetFile(f).metadata.num_rows for f in d.glob("*.parquet"))
    t = client.get_table(f"{project}.{dataset}.{d.name}")  # metadata only: no query cost
    ok = local == t.num_rows
    bad += not ok
    tables[d.name] = {"parquet_rows": local, "bigquery_rows": t.num_rows, "bigquery_bytes": t.num_bytes}
    print(f"  {d.name:20s} parquet {local:>13,}   bigquery {t.num_rows:>13,}   {'OK' if ok else 'MISMATCH'}")
record = {
    "run_id": run_id,
    "loaded_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat(),
    "project": project,
    "dataset": dataset,
    "gcs_prefix": gcs,
    "tables": tables,
    "loader_summary": json.loads((pathlib.Path(parquet) / "load_summary.json").read_text()),
}
pathlib.Path(out).write_text(json.dumps(record, indent=2, default=str))
print(f"  wrote {out}")
sys.exit(1 if bad else 0)
PY

step "Done. Next: bash scripts/build_bigquery.sh"
