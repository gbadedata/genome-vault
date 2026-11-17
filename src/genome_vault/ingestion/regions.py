"""Load genomic-context regions (BED) for one contig into Parquet.

The regions are the Genome in a Bottle (NIST) GRCh38 stratifications:
segmental duplications, low mappability, tandem repeats and homopolymers, and
the union of all difficult regions. The warehouse uses them to ask whether its
QC findings concentrate where short-read calling is known to be hard.

BED coordinates are 0-based and half-open. They are kept that way here
(start_0based, end_exclusive) so nothing is converted twice; the dbt models
do the one conversion when they compare with 1-based VCF positions.

Within each stratification, overlapping and touching intervals are merged, so
"bases covered" is a true count and a variant can only hit an interval once.
"""
from __future__ import annotations

import gzip
from dataclasses import dataclass
from pathlib import Path

import pyarrow as pa

from genome_vault.ingestion.alleles import normalise_contig
from genome_vault.ingestion.writer import TableWriter

# The stratifications the warehouse models expect (see variant_context.sql).
STRATIFICATIONS = ("segdup", "low_mappability", "tandem_repeat_homopolymer", "all_difficult")

REGION_SOURCE_SCHEMA = pa.schema(
    [
        ("stratification", pa.string()),
        ("path", pa.string()),
        ("sha256", pa.string()),
        ("intervals_read", pa.int64()),
        ("intervals_merged", pa.int64()),
        ("bases", pa.int64()),
        ("loaded_at", pa.timestamp("us", tz="UTC")),
    ]
)

REGION_SCHEMA = pa.schema(
    [
        ("stratification", pa.string()),
        ("chrom", pa.string()),
        ("start_0based", pa.int64()),
        ("end_exclusive", pa.int64()),
    ]
)


@dataclass(frozen=True)
class RegionSummary:
    stratification: str
    intervals_read: int
    intervals_merged: int
    bases: int


def read_bed(path: str | Path, contig: str) -> tuple[list[tuple[int, int]], int]:
    """Intervals on `contig`, sorted and merged. Returns (merged, read)."""
    opener = gzip.open if str(path).endswith(".gz") else open
    raw: list[tuple[int, int]] = []
    with opener(path, "rt") as f:
        for n, line in enumerate(f, 1):
            if line.startswith(("#", "track", "browser")) or not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3:
                raise ValueError(f"{path}:{n}: expected at least 3 tab-separated columns")
            if normalise_contig(cols[0]) != contig:
                continue
            start, end = int(cols[1]), int(cols[2])
            if not 0 <= start < end:
                raise ValueError(f"{path}:{n}: invalid interval {start}-{end}")
            raw.append((start, end))
    raw.sort()
    merged: list[tuple[int, int]] = []
    for start, end in raw:
        if merged and start <= merged[-1][1]:  # overlapping or touching
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged, len(raw)


def load_regions(beds: dict[str, str | Path], out: Path, contig: str = "chr22") -> list[RegionSummary]:
    """Write every stratification's merged intervals on `contig` to genome_regions."""
    writer = TableWriter(out, "genome_regions", REGION_SCHEMA)
    summaries = []
    for name, path in beds.items():
        merged, read = read_bed(path, contig)
        for start, end in merged:
            writer.append({"stratification": name, "chrom": contig, "start_0based": start, "end_exclusive": end})
        summaries.append(RegionSummary(name, read, len(merged), sum(e - s for s, e in merged)))
    writer.close()
    return summaries
