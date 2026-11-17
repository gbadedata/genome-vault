#!/usr/bin/env bash
# Extract gnomAD v3 genome allele frequencies for the development region from
# the BigQuery public dataset, for local development and CI.
#
#   bash scripts/fetch_gnomad_region.sh [start] [end]
#
# Runs a dry run first and prints the bytes the query will scan (BigQuery bills
# by columns scanned, not rows returned, so the region filter does not reduce
# cost). Stops if that is over MAX_GB (default 5). The first 1 TB of queries
# each month is free.
#
# gnomAD's start_position is 0-based (VCF POS - 1); it is kept as published
# here and converted in the warehouse, where a test checks the offset.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

START="${1:-42049000}"
END="${2:-42251000}"
MAX_GB="${MAX_GB:-5}"
OUT="tests/fixtures/real/gnomad_v3_chr22_${START}_${END}.csv"
# Billed to this project: GV_PROJECT_ID if set, else genome-vault-202605.
PROJECT="${GV_PROJECT_ID:-genome-vault-202605}"

SQL="SELECT
  v.reference_name, v.start_position, v.end_position, v.reference_bases, ab.alt,
  ARRAY_TO_STRING(v.filter, ';') AS filter,
  v.AN, v.AN_afr, v.AN_amr, v.AN_eas, v.AN_nfe, v.AN_sas,
  ab.AC, ab.AF, ab.nhomalt,
  ab.AC_afr, ab.AF_afr, ab.AC_amr, ab.AF_amr, ab.AC_eas, ab.AF_eas,
  ab.AC_nfe, ab.AF_nfe, ab.AC_sas, ab.AF_sas
FROM \`bigquery-public-data.gnomAD.v3_genomes__chr22\` AS v, UNNEST(v.alternate_bases) AS ab
WHERE v.start_position BETWEEN ${START} AND ${END}
ORDER BY v.start_position, v.reference_bases, ab.alt"

echo "project=$PROJECT region=${START}-${END}"
BYTES=$(bq query --project_id="$PROJECT" --use_legacy_sql=false --dry_run --format=json "$SQL" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['statistics']['totalBytesProcessed'])")
GB=$(python3 -c "print(f'{$BYTES/1e9:.2f}')")
echo "dry run: query will scan ${GB} GB"
python3 -c "import sys; sys.exit(0 if $BYTES/1e9 <= $MAX_GB else 1)" || { echo "over MAX_GB=$MAX_GB, stopping"; exit 1; }

bq query --project_id="$PROJECT" --use_legacy_sql=false --format=csv --max_rows=1000000 --quiet "$SQL" > "$OUT"
ROWS=$(($(wc -l < "$OUT") - 1))
echo "wrote $OUT ($ROWS rows, $(du -h "$OUT" | cut -f1))"
python3 - "$OUT" "$GB" "$ROWS" <<'PY'
import hashlib, json, sys, datetime as dt
path, gb, rows = sys.argv[1], sys.argv[2], int(sys.argv[3])
meta = {"table": "bigquery-public-data.gnomAD.v3_genomes__chr22", "path": path, "rows": rows,
        "scanned_gb": float(gb), "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest(),
        "retrieved_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()}
open(path + ".json", "w").write(json.dumps(meta, indent=2))
print(json.dumps(meta, indent=2))
PY
