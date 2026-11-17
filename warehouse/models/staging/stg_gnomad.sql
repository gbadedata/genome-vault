{{ config(materialized = 'table' if target.type == 'bigquery' else 'view') }}
-- gnomAD v3 genomes, one row per alternate allele. start_position in the
-- source is 0-based, so pos = start_position + 1 (VCF convention); the raw
-- value is kept so a test can prove the offset is right.
-- On BigQuery this is built once as a table: the public table is 19 GB, but
-- only these columns are scanned.
{% if target.type == 'bigquery' %}
select
    v.reference_name as chrom,
    v.start_position as start_position_0based,
    v.start_position + 1 as pos,
    v.reference_bases as ref,
    ab.alt as alt,
    array_to_string(v.filter, ';') as filter_status,
    v.AN as an, v.AN_afr as an_afr, v.AN_amr as an_amr, v.AN_eas as an_eas, v.AN_nfe as an_nfe, v.AN_sas as an_sas,
    ab.AC as ac, ab.AF as af,
    ab.AC_afr as ac_afr, ab.AF_afr as af_afr, ab.AC_amr as ac_amr, ab.AF_amr as af_amr,
    ab.AC_eas as ac_eas, ab.AF_eas as af_eas, ab.AC_nfe as ac_nfe, ab.AF_nfe as af_nfe,
    ab.AC_sas as ac_sas, ab.AF_sas as af_sas
from {{ source('gnomad_public', 'v3_genomes__chr22') }} as v, unnest(v.alternate_bases) as ab
{% else %}
select
    reference_name as chrom,
    start_position as start_position_0based,
    start_position + 1 as pos,
    reference_bases as ref,
    alt,
    filter as filter_status,
    AN as an, AN_afr as an_afr, AN_amr as an_amr, AN_eas as an_eas, AN_nfe as an_nfe, AN_sas as an_sas,
    AC as ac, AF as af,
    AC_afr as ac_afr, AF_afr as af_afr, AC_amr as ac_amr, AF_amr as af_amr,
    AC_eas as ac_eas, AF_eas as af_eas, AC_nfe as ac_nfe, AF_nfe as af_nfe,
    AC_sas as ac_sas, AF_sas as af_sas
from {{ source('gnomad_fixture', 'gnomad_v3_region') }}
{% endif %}
