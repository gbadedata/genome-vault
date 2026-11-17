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
# Usage:  bash scripts/load_bigquery.sh                # everything
#         bash scripts/load_bigquery.sh --skip-loader  # reuse the 1000 Genomes,
#                                                      # ClinVar and gene Parquet
#         bash scripts/load_bigquery.sh --skip-loader --tables genome_regions,genome_region_sources
#                                                      # upload and load only these
# The GIAB region tables are rebuilt on every run (a few seconds).
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
TABLES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-loader) SKIP_LOADER=1; shift ;;
    --tables) TABLES="${2:?--tables needs a comma-separated list}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$1"; }
fail() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

cd "$(dirname "$0")/.."

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
giab_path() {
  python - "$MANIFEST" "$1" <<'PY'
import json, sys
src = json.load(open(sys.argv[1]))["sources"].get(f"giab_{sys.argv[2]}")
print(src["chr22_path"] if src else "")
PY
}
REGION_ARGS=()
for strat in segdup low_mappability tandem_repeat_homopolymer all_difficult; do
  bed=$(giab_path "$strat")
  [[ -n "$bed" && -f "$bed" ]] || fail "GIAB $strat regions missing: run python scripts/fetch_sources.py --only giab"
  REGION_ARGS+=(--bed "$strat=$bed")
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

step "Loading GIAB difficult regions"
genome-vault regions "${REGION_ARGS[@]}" --contig chr22 --out "$PARQUET"

if [[ -n "$TABLES" ]]; then
  IFS=',' read -r -a SELECTED <<< "$TABLES"
  for t in "${SELECTED[@]}"; do
    [[ -d "$PARQUET/$t" ]] || fail "no Parquet for table $t in $PARQUET"
  done
else
  SELECTED=()
  for dir in "$PARQUET"/*/; do SELECTED+=("$(basename "$dir")"); done
fi
echo "  tables to upload: ${SELECTED[*]}"

# -----------------------------------------------------------------------------
step "Uploading Parquet to gs://$BUCKET/runs/$RUN_ID/"
for t in "${SELECTED[@]}"; do
  gcloud storage cp --recursive --project="$PROJECT" "$PARQUET/$t" "gs://$BUCKET/runs/$RUN_ID/parquet/"
done

# -----------------------------------------------------------------------------
step "Loading tables into $PROJECT:$RAW_DATASET"
for table in "${SELECTED[@]}"; do
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
python - "$PROJECT" "$RAW_DATASET" "$PARQUET" "$RUN_ID" "gs://$BUCKET/runs/$RUN_ID/parquet" "$WORK/bq_load.json" "${SELECTED[*]}" "$CODE_VERSION" <<'PY'
import datetime as dt
import json
import pathlib
import sys

import pyarrow.parquet as pq
from google.cloud import bigquery

project, dataset, parquet, run_id, gcs, out, uploaded, code_version = sys.argv[1:9]
client = bigquery.Client(project=project, location="US")
tables, bad = {}, 0
for d in sorted(p for p in pathlib.Path(parquet).iterdir() if p.is_dir()):
    local = sum(pq.ParquetFile(f).metadata.num_rows for f in d.glob("*.parquet"))
    t = client.get_table(f"{project}.{dataset}.{d.name}")  # metadata only: no query cost
    ok = local == t.num_rows
    bad += not ok
    tables[d.name] = {"parquet_rows": local, "bigquery_rows": t.num_rows, "bigquery_bytes": t.num_bytes}
    print(f"  {d.name:20s} parquet {local:>13,}   bigquery {t.num_rows:>13,}   {'OK' if ok else 'MISMATCH'}")
# Every table is checked, not only the ones uploaded this time: the others
# must still match the Parquet they were loaded from.
record = {
    "run_id": run_id,
    "code_version": code_version,
    "tables_uploaded": uploaded.split(),
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
