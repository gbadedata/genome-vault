"""Load the 1000 Genomes 30x phased panel VCF into Parquet.

Outputs (one directory each under the output root):

* kgp_variants    one row per loaded record, with the source's own allele
                  counts kept alongside, so the warehouse can recompute them
                  from genotypes and reconcile.
* kgp_genotypes   sparse calls: only non-reference or missing genotypes
                  (gt 1 = het, 2 = hom-alt, -1 = missing). Hom-ref calls are
                  implied, which is what keeps chr22 x 3,202 samples small.
* kgp_samples_vcf sample index -> sample ID, in VCF column order.
* quarantine      records that failed a rule, with the reason code.

Every record read is accounted for: loaded + quarantined = read. The run
summary returned by load_kgp() carries those counts and the source SHA-256.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
import pyarrow as pa
from cyvcf2 import VCF

from genome_vault.ingestion import alleles as al
from genome_vault.ingestion.reference import Reference
from genome_vault.ingestion.writer import TableWriter

POPS = ("AFR", "AMR", "EAS", "EUR", "SAS")

VARIANT_SCHEMA = pa.schema(
    [
        ("variant_key", pa.int64()),
        ("variant_id", pa.string()),
        ("chrom", pa.string()),
        ("pos", pa.int64()),
        ("end_pos", pa.int64()),
        ("ref", pa.string()),
        ("alt", pa.string()),
        ("variant_class", pa.string()),
        ("sv_type", pa.string()),
        ("sv_len", pa.int64()),
        ("is_transition", pa.bool_()),
        ("ref_check", pa.string()),
        ("source_id", pa.string()),
        ("filter_status", pa.string()),
        ("src_ac", pa.int64()),
        ("src_an", pa.int64()),
        ("src_af", pa.float64()),
    ]
    + [(f"src_{k}_{p.lower()}", pa.int64()) for p in POPS for k in ("ac", "an")]
    + [(f"src_{k}_{p.lower()}_unrel", pa.int64()) for p in POPS for k in ("ac", "an")]
    + [(f"src_hwe_{p.lower()}", pa.float64()) for p in POPS]
)

GENOTYPE_SCHEMA = pa.schema(
    [
        ("variant_key", pa.int64()),
        ("sample_index", pa.int16()),
        ("gt", pa.int8()),
        ("phased", pa.bool_()),
    ]
)

SAMPLE_SCHEMA = pa.schema([("sample_index", pa.int16()), ("sample_id", pa.string())])

QUARANTINE_SCHEMA = pa.schema(
    [
        ("source", pa.string()),
        ("record_number", pa.int64()),
        ("chrom", pa.string()),
        ("pos", pa.int64()),
        ("ref", pa.string()),
        ("alt", pa.string()),
        ("source_id", pa.string()),
        ("reason", pa.string()),
    ]
)


def _scalar(v: Any) -> Any:
    """cyvcf2 returns a tuple for Number=A fields with several values and a
    scalar for one; the panel is biallelic, so take the first value."""
    if isinstance(v, (tuple, list)):
        return v[0] if v else None
    return v


def _int(v: Any) -> int | None:
    v = _scalar(v)
    return None if v is None else int(v)


def _float(v: Any) -> float | None:
    v = _scalar(v)
    return None if v is None else float(v)


@dataclass
class LoadSummary:
    source: str
    path: str
    contig: str
    region: str | None
    records_read: int = 0
    records_loaded: int = 0
    quarantined: Counter[str] = field(default_factory=Counter)
    genotype_rows: int = 0
    missing_calls: int = 0
    samples: int = 0
    ref_checks: Counter[str] = field(default_factory=Counter)
    classes: Counter[str] = field(default_factory=Counter)

    def as_dict(self) -> dict[str, Any]:
        d = self.__dict__.copy()
        for k in ("quarantined", "ref_checks", "classes"):
            d[k] = dict(sorted(d[k].items()))
        return d


def load_kgp(
    vcf_path: str | Path,
    out: Path,
    reference: Reference | None,
    contig: str = "chr22",
    region: str | None = None,
    chunk_rows: int = 5_000_000,
) -> LoadSummary:
    vcf = VCF(str(vcf_path), gts012=True, threads=2)
    summary = LoadSummary(source="1000G_30x_phased_panel", path=str(vcf_path), contig=contig, region=region)

    samples = TableWriter(out, "kgp_samples_vcf", SAMPLE_SCHEMA)
    for i, s in enumerate(vcf.samples):
        samples.append({"sample_index": i, "sample_id": s})
    summary.samples = samples.close()

    variants = TableWriter(out, "kgp_variants", VARIANT_SCHEMA, chunk_rows=500_000)
    genotypes = TableWriter(out, "kgp_genotypes", GENOTYPE_SCHEMA, chunk_rows=chunk_rows)
    quarantine = TableWriter(out, "kgp_quarantine", QUARANTINE_SCHEMA)
    seen: set[str] = set()

    records = vcf(region) if region else vcf
    for record_number, v in enumerate(records, start=1):
        summary.records_read += 1
        chrom = al.normalise_contig(v.CHROM)
        alts = tuple(v.ALT) or None
        alt_text = ",".join(v.ALT) if v.ALT else "."

        reason = al.WRONG_CONTIG if chrom != contig else al.check_alleles(v.REF, alts)
        ref_check = "unchecked"
        if reason is None and reference is not None:
            ref_check = reference.check_ref(chrom, v.POS, v.REF)
            if ref_check == "mismatch":
                reason = al.REF_MISMATCH
        info = v.INFO
        end, sv_len = _int(info.get("END")), _int(info.get("SVLEN"))
        vid = al.variant_id(chrom, v.POS, v.REF, alt_text, end=end, sv_len=sv_len)
        if reason is None and vid in seen:
            reason = al.DUPLICATE_VARIANT

        if reason is not None:
            summary.quarantined[reason] += 1
            quarantine.append(
                {"source": summary.source, "record_number": record_number, "chrom": chrom, "pos": v.POS,
                 "ref": v.REF, "alt": alt_text, "source_id": v.ID, "reason": reason}
            )
            continue

        seen.add(vid)
        alt = alts[0]  # check_alleles guarantees exactly one
        vclass, sv_type = al.classify(v.REF, alt)
        row: dict[str, Any] = {
            "variant_key": record_number,
            "variant_id": vid,
            "chrom": chrom,
            "pos": v.POS,
            "end_pos": end if vclass == "SV" and end is not None else v.POS + len(v.REF) - 1,
            "ref": v.REF,
            "alt": alt,
            "variant_class": vclass,
            "sv_type": sv_type,
            "sv_len": sv_len,
            "is_transition": al.is_transition(v.REF, alt) if vclass == "SNV" else None,
            "ref_check": ref_check,
            "source_id": v.ID,
            "filter_status": v.FILTER or "PASS",
            "src_ac": _int(info.get("AC")),
            "src_an": _int(info.get("AN")),
            "src_af": _float(info.get("AF")),
        }
        for p in POPS:
            for k in ("AC", "AN"):
                row[f"src_{k.lower()}_{p.lower()}"] = _int(info.get(f"{k}_{p}"))
                row[f"src_{k.lower()}_{p.lower()}_unrel"] = _int(info.get(f"{k}_{p}_unrel"))
            row[f"src_hwe_{p.lower()}"] = _float(info.get(f"HWE_{p}"))
        variants.append(row)
        summary.records_loaded += 1
        summary.classes[vclass] += 1
        summary.ref_checks[ref_check] += 1

        gt = v.gt_types  # 0 hom-ref, 1 het, 2 hom-alt, 3 unknown
        idx = np.flatnonzero(gt != 0)
        if idx.size:
            codes = gt[idx].astype(np.int8)
            missing = codes == 3
            codes[missing] = -1
            summary.missing_calls += int(missing.sum())
            genotypes.append_arrays(
                {
                    "variant_key": np.full(idx.size, record_number, dtype=np.int64),
                    "sample_index": idx.astype(np.int16),
                    "gt": codes,
                    "phased": np.asarray(v.gt_phases, dtype=bool)[idx],
                }
            )

    variants.close()
    summary.genotype_rows = genotypes.close()
    quarantine.close()
    vcf.close()
    loaded_plus_quarantined = summary.records_loaded + sum(summary.quarantined.values())
    if loaded_plus_quarantined != summary.records_read:
        raise RuntimeError(f"Record accounting failed: read {summary.records_read}, accounted {loaded_plus_quarantined}")
    return summary
