"""The loader on the committed real slice: 1000 Genomes 30x chr22:42.05-42.25 Mb
(3,202 samples), ClinVar, Ensembl genes and the sample table. Expected numbers
come from the source files themselves (see tests/fixtures/real/SOURCES_MANIFEST.json)."""
from __future__ import annotations

import json

import duckdb
import pytest

pytestmark = pytest.mark.unit


def q(loaded, sql):
    con = duckdb.connect()
    for name in ("kgp_variants", "kgp_genotypes", "kgp_samples", "kgp_samples_vcf", "kgp_quarantine",
                 "clinvar_variants", "clinvar_quarantine", "ensembl_genes", "load_runs"):
        con.sql(f"create view {name} as select * from read_parquet('{loaded / name}/*.parquet')")
    return con.sql(sql).fetchall()


def test_every_record_is_accounted_for(loaded, real):
    manifest = json.loads((real / "SOURCES_MANIFEST.json").read_text())
    runs = {r[0]: r[1:] for r in q(loaded, "select source, records_read, records_loaded, records_quarantined from load_runs")}
    assert runs["1000G_30x_phased_panel"] == (manifest["fixtures"]["kgp_vcf"]["count"], 5452, 0)
    assert runs["ClinVar"] == (manifest["fixtures"]["clinvar_vcf"]["count"], 2365, 23)
    assert runs["1000G_samples"] == (3202, 3202, 0)


def test_clinvar_quarantine_is_records_without_an_alt_allele(loaded):
    assert q(loaded, "select reason, count(*) from clinvar_quarantine group by 1") == [("ALT_MISSING", 23)]


def test_ref_alleles_match_grch38(loaded):
    rows = dict(q(loaded, "select ref_check, count(*) from kgp_variants group by 1"))
    assert rows.get("mismatch", 0) == 0
    assert rows["match"] == 5451  # one deletion starts 2 bp before the slice: 'unchecked'
    assert rows["unchecked"] == 1


def test_variant_classes(loaded):
    assert dict(q(loaded, "select variant_class, count(*) from kgp_variants group by 1")) == {
        "SNV": 4708, "INDEL": 735, "SV": 9}


def test_genotypes_reproduce_source_allele_counts(loaded):
    """AC recomputed from 3,202 genotypes must equal the AC the source wrote in INFO."""
    mismatches = q(loaded, """
        with ac as (
          select variant_key, sum(case gt when 1 then 1 when 2 then 2 else 0 end) ac
          from kgp_genotypes group by 1)
        select count(*) from kgp_variants v left join ac using (variant_key)
        where coalesce(ac.ac, 0) <> v.src_ac""")
    assert mismatches == [(0,)]


def test_sparse_genotypes_only_hold_non_reference_calls(loaded):
    assert q(loaded, "select distinct gt from kgp_genotypes order by 1") == [(1,), (2,)]
    assert q(loaded, "select count(*), max(sample_index) from kgp_genotypes") == [(964_014, 3201)]


def test_every_vcf_sample_is_in_the_pedigree(loaded):
    assert q(loaded, "select count(*) from kgp_samples_vcf v anti join kgp_samples s using (sample_id)") == [(0,)]


def test_clinvar_contigs_are_normalised(loaded):
    assert q(loaded, "select distinct chrom from clinvar_variants") == [("chr22",)]


def test_structural_variant_identity_includes_end_and_length(loaded):
    rows = q(loaded, """select variant_id, pos, ref, alt, end_pos, sv_len from kgp_variants
                        where variant_class = 'SV' order by pos""")
    assert len(rows) == 9
    for vid, pos, ref, alt, end, sv_len in rows:
        assert vid == f"chr22:{pos}:{ref}:{alt}:{end}:{sv_len}"
    # sequence-resolved variants keep the plain chrom:pos:ref:alt form
    plain = q(loaded, """select count(*) from kgp_variants
                         where variant_class <> 'SV' and variant_id <> concat(chrom, ':', pos, ':', ref, ':', alt)""")
    assert plain == [(0,)]
