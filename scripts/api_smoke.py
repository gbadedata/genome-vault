"""Call every endpoint of a deployed genome-vault API and check the answers.

    python scripts/api_smoke.py https://genome-vault-api-....run.app --out data/work/evidence/api_smoke.json

Exits non-zero if any check fails. The JSON records each call's status,
latency and the fields checked, as evidence of the live deployment.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
from pathlib import Path
from urllib.parse import quote

import requests

NAGA_SNV = "chr22:42058350:G:A"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url")
    ap.add_argument("--expect-version")
    ap.add_argument("--backend", default="bigquery", help="backend /health should report")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    base = args.url.rstrip("/")
    results, failures = [], 0

    def check(path: str, status: int, test=lambda body: True, what: str = "") -> dict:
        nonlocal failures
        t0 = time.perf_counter()
        r = requests.get(base + path, timeout=60)
        ms = round((time.perf_counter() - t0) * 1000)
        try:
            body = r.json()
        except ValueError:
            body = None
        ok = r.status_code == status and (body is not None and test(body))
        failures += not ok
        results.append({"path": path, "status": r.status_code, "expected": status, "ms": ms, "ok": ok, "check": what})
        print(f"  {'OK  ' if ok else 'FAIL'} {r.status_code} {ms:>5} ms  {path}  {what}")
        if not ok:
            print(f"         response: {r.text[:300]}")
        return body or {}

    print(f"Smoke test of {base}")
    check("/health", 200, lambda b: b["status"] == "ok" and b["backend"] == args.backend
          and (args.expect_version is None or b["code_version"] == args.expect_version), "status, backend, version")
    v = check(f"/variants/{NAGA_SNV}", 200, lambda b: b["variant_id"] == NAGA_SNV and "NAGA" in b["genes"]
              and set(b["frequencies"]) >= {"AFR", "AMR", "EAS", "EUR", "SAS"}, "variant detail")
    check(f"/variants/{NAGA_SNV}", 200, lambda b: b == v, "same answer again (served from cache)")
    check("/variants?rsid=rs5758566", 200, lambda b: [x["variant_id"] for x in b["variants"]] == [NAGA_SNV], "rsID lookup")
    check("/variants?chrom=chr22&start=42126000&end=42131000&limit=500", 200,
          lambda b: b["count"] > 0 and all(42126000 <= x["pos"] <= 42131000 for x in b["variants"]), "region query")
    check("/variants?chrom=chr22&start=16000000&end=16999999&flagged_only=true&limit=50", 200,
          lambda b: all(x["hwe_departure"] or x["gnomad_af_discordant"] for x in b["variants"]), "flagged variants only")
    g = check("/genes/NAGA?limit=500", 200, lambda b: b["gene"]["gene_symbol"] == "NAGA"
              and b["returned"] == min(500, b["variants_overlapping"]), "gene and its variants")
    check("/samples/HG00096", 200, lambda b: b["population"] == "GBR", "sample QC")
    check("/qc/summary", 200, lambda b: b["invariants_passed"] is True, "every invariant passes")
    check("/qc/findings-by-region", 200, lambda b: len(b["rows"]) == 15, "findings by region class")
    sv = check("/variants?chrom=chr22&start=22857000&end=22857100", 200, lambda b: True, "structural variants at 22,857,056")
    for x in [x for x in sv.get("variants", []) if x["class"] == "SV"][:2]:
        check("/variants/" + quote(x["variant_id"], safe=":"), 200, lambda b, i=x["variant_id"]: b["variant_id"] == i,
              "structural variant by its END/SVLEN key")
    check("/variants/chr22:1:A:G", 404, what="unknown variant")
    check("/variants?chrom=chr22&start=1&end=5000000", 400, what="region too large")

    usage = requests.get(base + "/health", timeout=60).json()
    billed = usage.get("bigquery_bytes_billed_today")
    if billed is not None:
        print(f"  BigQuery billed so far today by this instance: {billed / 1e6:,.0f} MB "
              f"(daily budget {usage['bigquery_daily_budget_bytes'] / 1e9:,.0f} GB)")
    summary = {"url": base, "bigquery_bytes_billed_today": billed, "checked_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat(),
               "passed": len(results) - failures, "failed": failures, "gene_naga_variants": g.get("variants_overlapping"),
               "calls": results}
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(summary, indent=2))
        print(f"wrote {args.out}")
    print(f"{summary['passed']} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
