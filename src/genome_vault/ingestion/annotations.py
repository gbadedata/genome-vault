"""Small reference tables: Ensembl genes (GFF3) and the 1000 Genomes sample
pedigree/population table."""
from __future__ import annotations

import gzip
from pathlib import Path
from typing import Any

import pyarrow as pa

from genome_vault.ingestion.alleles import normalise_contig
from genome_vault.ingestion.writer import TableWriter

GENE_SCHEMA = pa.schema(
    [
        ("gene_id", pa.string()),
        ("gene_symbol", pa.string()),
        ("biotype", pa.string()),
        ("chrom", pa.string()),
        ("gene_start", pa.int64()),
        ("gene_end", pa.int64()),
        ("strand", pa.string()),
        ("feature_type", pa.string()),
    ]
)

SAMPLE_SCHEMA = pa.schema(
    [
        ("sample_id", pa.string()),
        ("family_id", pa.string()),
        ("father_id", pa.string()),
        ("mother_id", pa.string()),
        ("sex", pa.string()),
        ("population", pa.string()),
        ("superpopulation", pa.string()),
        ("has_parents_in_cohort", pa.bool_()),
        ("in_phase3_unrelated", pa.bool_()),
    ]
)

GENE_FEATURES = {"gene", "ncRNA_gene", "pseudogene"}


def _attrs(col9: str) -> dict[str, str]:
    out = {}
    for part in col9.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k] = v
    return out


def load_genes(gff3: str | Path, out: Path, contig: str = "chr22") -> int:
    w = TableWriter(out, "ensembl_genes", GENE_SCHEMA)
    opener = gzip.open if str(gff3).endswith(".gz") else open
    with opener(gff3, "rt") as f:
        for line in f:
            if line.startswith("#"):
                continue
            c = line.rstrip("\n").split("\t")
            if len(c) != 9 or c[2] not in GENE_FEATURES or normalise_contig(c[0]) != contig:
                continue
            a = _attrs(c[8])
            w.append(
                {
                    "gene_id": a.get("gene_id") or a.get("ID", "").removeprefix("gene:"),
                    "gene_symbol": a.get("Name"),
                    "biotype": a.get("biotype"),
                    "chrom": contig,
                    "gene_start": int(c[3]),
                    "gene_end": int(c[4]),
                    "strand": c[6],
                    "feature_type": c[2],
                }
            )
    return w.close()


def read_phase3_panel(path: str | Path) -> set[str]:
    """The 2,504 unrelated phase 3 samples (tab-separated: sample pop super_pop
    gender). These are the samples behind the panel's *_unrel allele counts;
    having no parents in the cohort is not enough (siblings and other relatives
    also have none)."""
    with open(path) as f:
        header = f.readline().split()
        if header[:1] != ["sample"]:
            raise ValueError(f"Unexpected phase 3 panel header: {header}")
        return {line.split()[0] for line in f if line.strip()}


def load_samples(ped: str | Path, out: Path, phase3_panel: str | Path | None = None) -> int:
    """The EBI table is space-separated: FamilyID SampleID FatherID MotherID Sex
    Population Superpopulation; '0' means no parent in the cohort."""
    unrelated = read_phase3_panel(phase3_panel) if phase3_panel else None
    w = TableWriter(out, "kgp_samples", SAMPLE_SCHEMA)
    sex = {"1": "male", "2": "female"}
    with open(ped) as f:
        header = f.readline().split()
        if header[:2] != ["FamilyID", "SampleID"]:
            raise ValueError(f"Unexpected sample table header: {header}")
        for line in f:
            c = line.split()
            if not c:
                continue
            row: dict[str, Any] = {
                "family_id": c[0],
                "sample_id": c[1],
                "father_id": None if c[2] == "0" else c[2],
                "mother_id": None if c[3] == "0" else c[3],
                "sex": sex.get(c[4], "unknown"),
                "population": c[5],
                "superpopulation": c[6],
            }
            row["has_parents_in_cohort"] = row["father_id"] is not None or row["mother_id"] is not None
            row["in_phase3_unrelated"] = None if unrelated is None else row["sample_id"] in unrelated
            w.append(row)
    return w.close()
