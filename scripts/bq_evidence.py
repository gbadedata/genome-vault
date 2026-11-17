"""Record what a BigQuery dbt build did, as JSON and Markdown in docs/evidence/.

Collects:
  - dbt results per node (status, time) from target/run_results.json;
  - the qc_summary table (invariants and findings);
  - row counts and sizes of the warehouse tables (table metadata, no query cost);
  - the BigQuery jobs dbt ran, with bytes processed and billed, from
    INFORMATION_SCHEMA.JOBS_BY_USER (dbt labels its jobs; see dbt_project.yml);
  - what the findings are: rates by GIAB region class, flagged samples by
    population, ClinVar pathogenic calls that are common, quarantined records;
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
    "qc_sample", "gnomad_concordance", "clinvar_in_cohort", "variant_context",
    "findings_by_region_class", "qc_summary",
]


def gb(n: int | None) -> float | None:
    return None if n is None else round(n / 1e9, 3)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project", required=True)
    ap.add_argument("--dataset", default="gv")
    ap.add_argument("--raw-dataset", default="gv_raw")
    ap.add_argument("--since", required=True, help="UTC start of the dbt run, ISO 8601")
    ap.add_argument("--run-results", required=True, type=Path)
    ap.add_argument("--load-record", type=Path)
    ap.add_argument("--code-version", default="unknown", help="git commit the run used")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    client = bigquery.Client(project=args.project, location="US")
    evidence: dict = {"generated_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat(),
                      "project": args.project, "dataset": args.dataset, "code_version": args.code_version}

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

    # What the findings are (small queries; each reads at most a few MB)
    ds, raw = f"`{args.project}.{args.dataset}`", f"`{args.project}.{args.raw_dataset}`"
    finding_queries = {
        "by_region_class": f"""
            select finding, region_class, variants, with_finding, rate, share_of_variants, share_of_findings,
                   rate_ratio, rate_ratio_ci_low, rate_ratio_ci_high
            from {ds}.findings_by_region_class order by finding, rate_ratio desc""",
        "variants_by_region_class": f"""
            select region_class, count(*) as variants from {ds}.variant_context group by region_class order by variants desc""",
        "region_sources": f"""
            select stratification, intervals_read, intervals_merged, bases, sha256
            from {ds}.stg_genome_region_sources order by stratification""",
        "flagged_samples_by_population": f"""
            select superpopulation, population, count(*) as samples,
                   sum(case when abs(coalesce(ti_tv_z, 0)) > 4 then 1 else 0 end) as on_ti_tv,
                   sum(case when abs(coalesce(het_hom_z, 0)) > 4 then 1 else 0 end) as on_het_hom,
                   sum(case when abs(coalesce(non_ref_z, 0)) > 4 then 1 else 0 end) as on_non_ref_sites,
                   round(avg(het_hom_z), 1) as mean_het_hom_z,
                   sum(case when is_unrelated then 0 else 1 end) as outside_unrelated_set
            from {ds}.qc_sample where flagged
            group by superpopulation, population order by samples desc""",
        "sample_flags_compared": f"""
            select
                sum(case when flagged then 1 else 0 end) as within_population,
                sum(case when flagged_by_superpop then 1 else 0 end) as within_superpopulation,
                sum(case when flagged and flagged_by_superpop then 1 else 0 end) as both,
                sum(case when flagged_by_superpop and not flagged then 1 else 0 end) as superpopulation_only,
                sum(case when flagged and not flagged_by_superpop then 1 else 0 end) as population_only
            from {ds}.qc_sample""",
        "clinvar_common_pathogenic": f"""
            select variant_id, rsid, gene_symbols, clinical_significance, clinvar_review_status,
                   max_pop, round(max_pop_af, 4) as max_pop_af
            from {ds}.clinvar_in_cohort where common_but_pathogenic""",
        "quarantined_1000g_records": f"select * from {raw}.kgp_quarantine",
    }
    evidence["findings"] = {}
    for key, sql in finding_queries.items():
        try:
            evidence["findings"][key] = [dict(r) for r in client.query(sql).result()]
        except Exception as exc:
            evidence["findings"][key] = {"error": str(exc)[:300]}

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
             f"Project `{e['project']}`, dataset `{e['dataset']}`, location US, code version `{e.get('code_version', 'unknown')}`.", ""]
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
    f = e.get("findings", {})

    def table(rows, cols: list[tuple[str, str]], fmt=None) -> list[str]:
        if not isinstance(rows, list):
            return [f"(not available: {rows})", ""]
        out = ["| " + " | ".join(h for _, h in cols) + " |", "|" + "---|" * len(cols)]
        for r in rows:
            out.append("| " + " | ".join(_cell(r.get(k)) for k, _ in cols) + " |")
        return out + [""]

    lines += ["## Findings by GIAB region class", "",
              "Rate of each finding per variant, and its ratio to the rate in not-difficult regions (95% interval).", ""]
    lines += table(f.get("by_region_class"), [
        ("finding", "Finding"), ("region_class", "Region class"), ("variants", "Variants"),
        ("with_finding", "With finding"), ("rate", "Rate"), ("rate_ratio", "Ratio"),
        ("rate_ratio_ci_low", "95% low"), ("rate_ratio_ci_high", "95% high")])
    lines += ["Variants by region class:", ""]
    lines += table(f.get("variants_by_region_class"), [("region_class", "Region class"), ("variants", "Variants")])
    lines += ["GIAB regions loaded (chr22):", ""]
    lines += table(f.get("region_sources"), [
        ("stratification", "Stratification"), ("intervals_merged", "Intervals"), ("bases", "Bases")])
    lines += ["## Flagged samples", "",
              "Flags use z-scores within each sample's population; superpopulation flags are shown for comparison.", ""]
    lines += table(f.get("sample_flags_compared"), [
        ("within_population", "Within population"), ("within_superpopulation", "Within superpopulation"),
        ("both", "Both"), ("superpopulation_only", "Superpopulation only"), ("population_only", "Population only")])
    lines += ["Flagged within population, by population:", ""]
    lines += table(f.get("flagged_samples_by_population"), [
        ("superpopulation", "Superpop."), ("population", "Population"), ("samples", "Samples"),
        ("on_ti_tv", "Ti/Tv"), ("on_het_hom", "Het/hom"), ("on_non_ref_sites", "Non-ref sites"),
        ("mean_het_hom_z", "Mean het/hom z"), ("outside_unrelated_set", "Not in unrelated set")])
    lines += ["## ClinVar pathogenic calls common in a population", ""]
    lines += table(f.get("clinvar_common_pathogenic"), [
        ("variant_id", "Variant"), ("rsid", "rsID"), ("gene_symbols", "Genes"),
        ("clinical_significance", "Significance"), ("clinvar_review_status", "Review status"),
        ("max_pop", "Population"), ("max_pop_af", "AF")])
    lines += ["## Quarantined 1000 Genomes records", ""]
    lines += table(f.get("quarantined_1000g_records"), [
        ("record_number", "Record"), ("chrom", "Chrom"), ("pos", "Pos"), ("ref", "Ref"), ("alt", "Alt"),
        ("source_id", "Source ID"), ("reason", "Reason")])

    lines += ["## Tables", "", "| Table | Type | Rows | GB |", "|---|---|---:|---:|"]
    for k, v in e["tables"].items():
        if v:
            rows = "" if v["rows"] is None else f"{v['rows']:,}"
            lines.append(f"| {k} | {v['type']} | {rows} | {v['gb'] if v['gb'] is not None else ''} |")
    return "\n".join(lines) + "\n"


def _cell(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float):
        return f"{v:.3g}" if abs(v) < 1000 else f"{v:,.0f}"
    if isinstance(v, int):
        return f"{v:,}"
    s = str(v).replace("|", "/")
    return s if len(s) <= 60 else s[:57] + "..."


if __name__ == "__main__":
    main()
