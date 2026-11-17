"""Allele classification and validation rules shared by every VCF loader.

Each rule returns a reason code, or None when the record passes. Reason codes
are stable strings: they are stored with every quarantined record and counted
in the load manifest, so they must not be renamed casually.
"""
from __future__ import annotations

import re

NUCLEOTIDES = re.compile(r"^[ACGTN]+$")
SYMBOLIC = re.compile(r"^<[^<>,\s]+>$")  # VCF 4.2: any ID without whitespace, commas or angle brackets
TRANSITIONS = {("A", "G"), ("G", "A"), ("C", "T"), ("T", "C")}

REF_INVALID = "REF_INVALID"
ALT_INVALID = "ALT_INVALID"
ALT_MISSING = "ALT_MISSING"
MULTIALLELIC = "MULTIALLELIC"
WRONG_CONTIG = "WRONG_CONTIG"
REF_MISMATCH = "REF_MISMATCH"
DUPLICATE_VARIANT = "DUPLICATE_VARIANT"

REASON_CODES = (
    REF_INVALID, ALT_INVALID, ALT_MISSING, MULTIALLELIC,
    WRONG_CONTIG, REF_MISMATCH, DUPLICATE_VARIANT,
)


def normalise_contig(name: str) -> str:
    """'22' and 'chr22' both become 'chr22' (ClinVar and Ensembl omit 'chr')."""
    return name if name.startswith("chr") else f"chr{name}"


def classify(ref: str, alt: str) -> tuple[str, str | None]:
    """Return (variant_class, sv_type). Classes: SNV, MNV, INDEL, SV."""
    if SYMBOLIC.match(alt):
        return "SV", alt[1:-1]
    if len(ref) == 1 and len(alt) == 1:
        return "SNV", None
    if len(ref) == len(alt):
        return "MNV", None
    return "INDEL", None


def is_transition(ref: str, alt: str) -> bool:
    return (ref, alt) in TRANSITIONS


def check_alleles(ref: str, alts: tuple[str, ...] | None) -> str | None:
    """Structural checks that need no reference genome."""
    if not ref or not NUCLEOTIDES.match(ref.upper()):
        return REF_INVALID
    if not alts or alts == (".",) or alts == ("*",):
        return ALT_MISSING
    if len(alts) > 1:
        return MULTIALLELIC
    alt = alts[0]
    if not (NUCLEOTIDES.match(alt.upper()) or SYMBOLIC.match(alt)):
        return ALT_INVALID
    return None


def variant_id(chrom: str, pos: int, ref: str, alt: str) -> str:
    return f"{chrom}:{pos}:{ref}:{alt}"
