"""Load ClinVar (GRCh38 VCF) records for one contig into Parquet.

ClinVar names contigs '22', not 'chr22'; contigs are normalised so the
warehouse can join to 1000 Genomes on (chrom, pos, ref, alt). Records with no
alternate allele, or a REF that disagrees with GRCh38, are quarantined with a
reason code rather than dropped.
"""
from __future__ import annotations

from collections import Counter
from pathlib import Path
from typing import Any

import pyarrow as pa
from cyvcf2 import VCF

from genome_vault.ingestion import alleles as al
from genome_vault.ingestion.kgp import QUARANTINE_SCHEMA
from genome_vault.ingestion.reference import Reference
from genome_vault.ingestion.writer import TableWriter

CLINVAR_SCHEMA = pa.schema(
    [
        ("variant_id", pa.string()),
        ("chrom", pa.string()),
        ("pos", pa.int64()),
        ("ref", pa.string()),
        ("alt", pa.string()),
        ("clinvar_variation_id", pa.string()),
        ("allele_id", pa.string()),
        ("rsid", pa.string()),
        ("clinical_significance", pa.string()),
        ("review_status", pa.string()),
        ("gene_symbols", pa.string()),
        ("conditions", pa.string()),
        ("molecular_consequence", pa.string()),
        ("variant_type", pa.string()),
        ("ref_check", pa.string()),
    ]
)


def _text(v: Any) -> str | None:
    if v is None:
        return None
    return ",".join(map(str, v)) if isinstance(v, (tuple, list)) else str(v)


def _genes(geneinfo: str | None) -> str | None:
    """'NAGA:4668|WBP2NL:164684' -> 'NAGA|WBP2NL'."""
    if not geneinfo:
        return None
    return "|".join(g.split(":")[0] for g in geneinfo.split("|"))


def load_clinvar(
    vcf_path: str | Path, out: Path, reference: Reference | None, contig: str = "chr22", region: str | None = None
) -> dict[str, Any]:
    vcf = VCF(str(vcf_path))
    rows = TableWriter(out, "clinvar_variants", CLINVAR_SCHEMA)
    quarantine = TableWriter(out, "clinvar_quarantine", QUARANTINE_SCHEMA)
    read = 0
    reasons: Counter[str] = Counter()
    source_contig = contig.removeprefix("chr")  # ClinVar uses '22'
    it = vcf(region.replace(contig, source_contig, 1) if region else source_contig)
    for record_number, v in enumerate(it, start=1):
        read += 1
        chrom = al.normalise_contig(v.CHROM)
        alts = tuple(v.ALT) or None
        alt_text = ",".join(v.ALT) if v.ALT else "."
        reason = al.check_alleles(v.REF, alts)
        ref_check = "unchecked"
        if reason is None and reference is not None:
            ref_check = reference.check_ref(chrom, v.POS, v.REF)
            if ref_check == "mismatch":
                reason = al.REF_MISMATCH
        if reason is not None:
            reasons[reason] += 1
            quarantine.append(
                {"source": "ClinVar", "record_number": record_number, "chrom": chrom, "pos": v.POS,
                 "ref": v.REF, "alt": alt_text, "source_id": v.ID, "reason": reason}
            )
            continue
        info = v.INFO
        rs = info.get("RS")
        rows.append(
            {
                "variant_id": al.variant_id(chrom, v.POS, v.REF, alts[0]),
                "chrom": chrom,
                "pos": v.POS,
                "ref": v.REF,
                "alt": alts[0],
                "clinvar_variation_id": v.ID,
                "allele_id": _text(info.get("ALLELEID")),
                "rsid": f"rs{rs}" if rs else None,
                "clinical_significance": _text(info.get("CLNSIG")),
                "review_status": _text(info.get("CLNREVSTAT")),
                "gene_symbols": _genes(_text(info.get("GENEINFO"))),
                "conditions": _text(info.get("CLNDN")),
                "molecular_consequence": _text(info.get("MC")),
                "variant_type": _text(info.get("CLNVC")),
                "ref_check": ref_check,
            }
        )
    loaded = rows.close()
    quarantine.close()
    vcf.close()
    if loaded + sum(reasons.values()) != read:
        raise RuntimeError(f"ClinVar accounting failed: read {read}, loaded {loaded}, quarantined {sum(reasons.values())}")
    return {"source": "ClinVar", "path": str(vcf_path), "records_read": read, "records_loaded": loaded,
            "quarantined": dict(sorted(reasons.items()))}
