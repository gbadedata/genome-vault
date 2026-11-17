"""Rules on small hand-written cases; the real-data behaviour is tested in
test_load_real_slice.py."""
from __future__ import annotations

import pytest

from genome_vault.ingestion import alleles as al
from genome_vault.ingestion.reference import Reference

pytestmark = pytest.mark.unit


@pytest.mark.parametrize(
    ("ref", "alt", "expected"),
    [
        ("A", "G", ("SNV", None)),
        ("AC", "GT", ("MNV", None)),
        ("AAAG", "A", ("INDEL", None)),
        ("G", "<DEL:ME:SINE|Alu|AluY>", ("SV", "DEL:ME:SINE|Alu|AluY")),
        ("T", "<INS:ME:ALU>", ("SV", "INS:ME:ALU")),
    ],
)
def test_classify(ref, alt, expected):
    assert al.classify(ref, alt) == expected


@pytest.mark.parametrize(
    ("ref", "alts", "reason"),
    [
        ("A", ("G",), None),
        ("G", ("<DUP>",), None),
        ("G", ("<DEL:ME:SINE|Alu|AluY>",), None),  # lowercase is legal in symbolic IDs
        ("A", None, al.ALT_MISSING),
        ("A", (".",), al.ALT_MISSING),
        ("A", ("G", "T"), al.MULTIALLELIC),
        ("A", ("X",), al.ALT_INVALID),
        ("A", ("<D L>",), al.ALT_INVALID),
        ("", ("G",), al.REF_INVALID),
        ("R", ("G",), al.REF_INVALID),
    ],
)
def test_check_alleles(ref, alts, reason):
    assert al.check_alleles(ref, alts) == reason


def test_transitions():
    assert al.is_transition("A", "G") and al.is_transition("C", "T")
    assert not al.is_transition("A", "C")


def test_contig_normalisation():
    assert al.normalise_contig("22") == "chr22"
    assert al.normalise_contig("chr22") == "chr22"


def test_reference_slice_offsets(tmp_path):
    fa = tmp_path / "s.fa"
    fa.write_text(">chr22:101-110\nACGTN\nACGTA\n")
    ref = Reference.from_fasta(fa)
    assert (ref.start, ref.end) == (101, 110)
    assert ref.check_ref("chr22", 101, "ACG") == "match"
    assert ref.check_ref("chr22", 105, "G") == "match"  # N matches anything
    assert ref.check_ref("chr22", 102, "A") == "mismatch"
    assert ref.check_ref("chr22", 100, "AA") == "unchecked"  # starts before the slice
    assert ref.check_ref("chr22", 110, "AC") == "unchecked"  # runs past the end
    assert ref.check_ref("chr21", 101, "A") == "unchecked"


def test_symbolic_alleles_carry_end_and_length_in_their_identity():
    # Illustrative values for the function on its own: two deletions of
    # different lengths starting at the same base must not share an identity.
    # The real structural variants are checked in test_load_real_slice.py.
    a = al.variant_id("chr22", 22857056, "T", "<DEL>", end=22857500, sv_len=-444)
    b = al.variant_id("chr22", 22857056, "T", "<DEL>", end=22861000, sv_len=-3944)
    assert a != b
    assert a == "chr22:22857056:T:<DEL>:22857500:-444"


def test_sequence_resolved_alleles_keep_the_plain_identity():
    assert al.variant_id("chr22", 42126611, "C", "G", end=42126611, sv_len=None) == "chr22:42126611:C:G"
