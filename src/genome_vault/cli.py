"""genome-vault command line.

    genome-vault load \\
        --kgp-vcf  data/full/1kGP_high_coverage_Illumina.chr22...vcf.gz \\
        --clinvar  data/full/clinvar.vcf.gz \\
        --genes    data/full/ensembl_genes_22.gff3.gz \\
        --samples  data/full/20130606_g1k_3202_samples_ped_population.txt \\
        --reference data/full/chr22.fa.gz \\
        --out      data/work/parquet

Writes one Parquet directory per table plus load_runs (what was read, loaded
and quarantined, with the source SHA-256) and load_summary.json.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import time
from pathlib import Path
from typing import Any

import click
import pyarrow as pa

from genome_vault.ingestion.annotations import load_genes, load_samples
from genome_vault.ingestion.clinvar import load_clinvar
from genome_vault.ingestion.kgp import load_kgp
from genome_vault.ingestion.reference import Reference
from genome_vault.ingestion.writer import TableWriter

RUN_SCHEMA = pa.schema(
    [
        ("run_id", pa.string()),
        ("source", pa.string()),
        ("path", pa.string()),
        ("sha256", pa.string()),
        ("records_read", pa.int64()),
        ("records_loaded", pa.int64()),
        ("records_quarantined", pa.int64()),
        ("quarantine_reasons", pa.string()),
        ("genotype_rows", pa.int64()),
        ("missing_calls", pa.int64()),
        ("samples", pa.int64()),
        ("region", pa.string()),
        ("seconds", pa.float64()),
        ("loaded_at", pa.timestamp("us", tz="UTC")),
    ]
)


def sha256(path: str | Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@click.group()
def main() -> None:
    """genome-vault: real 1000 Genomes, ClinVar and Ensembl data into a warehouse."""


@main.command()
@click.option("--kgp-vcf", required=True, type=click.Path(exists=True, dir_okay=False))
@click.option("--clinvar", "clinvar_vcf", required=True, type=click.Path(exists=True, dir_okay=False))
@click.option("--genes", required=True, type=click.Path(exists=True, dir_okay=False))
@click.option("--samples", required=True, type=click.Path(exists=True, dir_okay=False))
@click.option("--unrelated-panel", type=click.Path(exists=True, dir_okay=False),
              help="phase 3 panel of 2,504 unrelated samples")
@click.option("--reference", type=click.Path(exists=True, dir_okay=False), help="GRCh38 chr22 FASTA (plain or .gz)")
@click.option("--out", required=True, type=click.Path(file_okay=False, path_type=Path))
@click.option("--contig", default="chr22", show_default=True)
@click.option("--region", default=None, help="e.g. chr22:42050000-42250000 (needs an indexed VCF)")
def load(kgp_vcf: str, clinvar_vcf: str, genes: str, samples: str, unrelated_panel: str | None,
         reference: str | None, out: Path, contig: str, region: str | None) -> None:
    """Load every source for one contig into Parquet."""
    out.mkdir(parents=True, exist_ok=True)
    run_id = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    ref = Reference.from_fasta(reference) if reference else None
    runs = TableWriter(out, "load_runs", RUN_SCHEMA)
    report: dict[str, Any] = {"run_id": run_id, "contig": contig, "region": region, "sources": {}}

    def record(source: str, path: str, t0: float, read: int, loaded: int, reasons: dict[str, int],
               genotype_rows: int = 0, missing: int = 0, n_samples: int = 0) -> None:
        row = {
            "run_id": run_id, "source": source, "path": path, "sha256": sha256(path),
            "records_read": read, "records_loaded": loaded, "records_quarantined": sum(reasons.values()),
            "quarantine_reasons": json.dumps(reasons, sort_keys=True), "genotype_rows": genotype_rows,
            "missing_calls": missing, "samples": n_samples, "region": region,
            "seconds": round(time.monotonic() - t0, 2), "loaded_at": dt.datetime.now(dt.UTC),
        }
        runs.append(row)
        report["sources"][source] = {k: v for k, v in row.items() if k not in ("run_id", "loaded_at")}
        click.echo(f"  {source}: read {read:,}, loaded {loaded:,}, quarantined {sum(reasons.values()):,} {reasons or ''}")

    click.echo(f"run {run_id}")
    t0 = time.monotonic()
    s = load_kgp(kgp_vcf, out, ref, contig=contig, region=region)
    record("1000G_30x_phased_panel", kgp_vcf, t0, s.records_read, s.records_loaded, dict(s.quarantined),
           s.genotype_rows, s.missing_calls, s.samples)
    report["sources"]["1000G_30x_phased_panel"].update(classes=dict(s.classes), ref_checks=dict(s.ref_checks))

    t0 = time.monotonic()
    c = load_clinvar(clinvar_vcf, out, ref, contig=contig, region=region)
    record("ClinVar", clinvar_vcf, t0, c["records_read"], c["records_loaded"], c["quarantined"])

    t0 = time.monotonic()
    n = load_genes(genes, out, contig=contig)
    record("Ensembl_genes", genes, t0, n, n, {})

    t0 = time.monotonic()
    n = load_samples(samples, out, unrelated_panel)
    record("1000G_samples", samples, t0, n, n, {})

    runs.close()
    (out / "load_summary.json").write_text(json.dumps(report, indent=2, default=str))
    click.echo(f"wrote {out}")


if __name__ == "__main__":
    main()
