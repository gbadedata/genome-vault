"""Record what a BigQuery dbt build did, as JSON and Markdown in docs/evidence/.

Collects:
  - dbt results per node (status, time) from target/run_results.json;
  - the qc_summary table (invariants and findings);
  - row counts and sizes of the warehouse tables (table metadata, no query cost);
  - the BigQuery jobs dbt ran, with bytes processed and billed, from
    INFORMATION_SCHEMA.JOBS_BY_USER (dbt labels its jobs; see dbt_project.yml);
  - the load record written by scripts/load_bigquery.sh.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from collections import Counter
from pathlib import Path

from google.cloud import bigquery

WAREHOUSE_TABLES = [
    "dim_sample", "dim_population", "dim_variant", "fct_genotype", "stg_gnomad",
    "variant_population_freq", "qc_allele_count_reconciliation", "qc_hardy_weinberg",
    "qc_sample", "gnomad_concordance", "clinvar_in_cohort", "qc_summary",
]


def gb(n: int | None) -> float | None:
    return None if n is None else round(n / 1e9, 3)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project", required=True)
    ap.add_argument("--dataset", default="gv")
    ap.add_argument("--since", required=True, help="UTC start of the dbt run, ISO 8601")
    ap.add_argument("--run-results", required=True, type=Path)
    ap.add_argument("--load-record", type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    client = bigquery.Client(project=args.project, location="US")
    evidence: dict = {"generated_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat(),
                      "project": args.project, "dataset": args.dataset}

    # dbt results
    if args.run_results.exists():
        rr = json.loads(args.run_results.read_text())
        statuses = Counter(r["status"] for r in rr["results"])
        evidence["dbt"] = {
            "invocation_id": rr["metadata"]["invocation_id"],
            "dbt_version": rr["metadata"]["dbt_version"],
            "elapsed_seconds": round(rr.get("elapsed_time", 0), 1),
            "statuses": dict(statuses),
            "not_passing": [{"node": r["unique_id"], "status": r["status"], "message": r.get("message")}
                            for r in rr["results"] if r["status"] not in ("success", "pass")],
        }
        invocation_id = rr["metadata"]["invocation_id"]
    else:
        evidence["dbt"] = {"error": f"{args.run_results} not found"}
        invocation_id = None

    # QC summary
    try:
        rows = client.query(f"select kind, check_name, passed, detail from `{args.project}.{args.dataset}.qc_summary`").result()
        evidence["qc_summary"] = [dict(r) for r in rows]
    except Exception as exc:  # the build may have failed before qc_summary existed
        evidence["qc_summary"] = {"error": str(exc)[:500]}

    # Table sizes (metadata only)
    sizes = {}
    for name in WAREHOUSE_TABLES:
        try:
            t = client.get_table(f"{args.project}.{args.dataset}.{name}")
            sizes[name] = {"type": t.table_type, "rows": t.num_rows, "gb": gb(t.num_bytes)}
        except Exception:
            sizes[name] = None
    evidence["tables"] = sizes

    # Jobs and bytes billed
    jobs_sql = """
        select
          job_id,
          (select value from unnest(labels) where key = 'node_id') as node_id,
          (select value from unnest(labels) where key = 'dbt_invocation_id') as invocation_id,
          statement_type,
          total_bytes_processed,
          total_bytes_billed,
          timestamp_diff(end_time, start_time, millisecond) / 1000 as seconds,
          error_result.message as error
        from `region-us`.INFORMATION_SCHEMA.JOBS_BY_USER
        where creation_time >= @since
          and project_id = @project
          and job_type = 'QUERY'
          and exists (select 1 from unnest(labels) where key = 'app' and value = 'dbt')
    """
    cfg = bigquery.QueryJobConfig(query_parameters=[
        bigquery.ScalarQueryParameter("since", "TIMESTAMP", args.since),
        bigquery.ScalarQueryParameter("project", "STRING", args.project),
    ])
    jobs = [dict(r) for r in client.query(jobs_sql, job_config=cfg).result()]
    if invocation_id and any(j["invocation_id"] for j in jobs):
        jobs = [j for j in jobs if j["invocation_id"] == invocation_id]
    billed = [j["total_bytes_billed"] or 0 for j in jobs]
    evidence["bigquery_jobs"] = {
        "count": len(jobs),
        "gb_processed": gb(sum(j["total_bytes_processed"] or 0 for j in jobs)),
        "gb_billed": gb(sum(billed)),
        "largest_single_query_gb_billed": gb(max(billed) if billed else 0),
        "errors": [j for j in jobs if j["error"]],
        "top_by_bytes_billed": sorted(
            ({"node_id": j["node_id"], "gb_billed": gb(j["total_bytes_billed"]), "seconds": j["seconds"]} for j in jobs),
            key=lambda j: j["gb_billed"] or 0, reverse=True)[:8],
    }

    if args.load_record and args.load_record.exists():
        evidence["load"] = json.loads(args.load_record.read_text())

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "bigquery_full_chr22.json").write_text(json.dumps(evidence, indent=2, default=str))
    (args.out / "bigquery_full_chr22.md").write_text(render(evidence))
    print(render(evidence))
    print(f"wrote {args.out / 'bigquery_full_chr22.json'} and .md")


def render(e: dict) -> str:
    lines = [f"# BigQuery build on full chromosome 22 ({e['generated_at']})", "",
             f"Project `{e['project']}`, dataset `{e['dataset']}`, location US.", ""]
    load = e.get("load")
    if load:
        lines += ["## Load", "", f"Run `{load['run_id']}` from `{load['gcs_prefix']}`.", "",
                  "| Table | Parquet rows | BigQuery rows |", "|---|---:|---:|"]
        lines += [f"| {k} | {v['parquet_rows']:,} | {v['bigquery_rows']:,} |" for k, v in load["tables"].items()]
        lines.append("")
    d = e.get("dbt", {})
    lines += ["## dbt build", "", f"Statuses: {d.get('statuses')}, {d.get('elapsed_seconds')} s, dbt {d.get('dbt_version')}.", ""]
    for n in d.get("not_passing", []):
        lines.append(f"- {n['status']}: {n['node']}: {n['message']}")
    qc = e.get("qc_summary")
    if isinstance(qc, list):
        lines += ["", "## QC summary", "", "| Kind | Check | Passed | Detail |", "|---|---|---|---|"]
        lines += [f"| {r['kind']} | {r['check_name']} | {r['passed']} | {r['detail']} |" for r in qc]
    j = e["bigquery_jobs"]
    lines += ["", "## Cost", "",
              f"{j['count']} queries; {j['gb_processed']} GB processed, {j['gb_billed']} GB billed; "
              f"largest single query {j['largest_single_query_gb_billed']} GB (cap 20 GB).", ""]
    lines += ["## Tables", "", "| Table | Type | Rows | GB |", "|---|---|---:|---:|"]
    for k, v in e["tables"].items():
        if v:
            rows = "" if v["rows"] is None else f"{v['rows']:,}"
            lines.append(f"| {k} | {v['type']} | {rows} | {v['gb'] if v['gb'] is not None else ''} |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
