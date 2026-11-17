{{ config(materialized = 'table', cluster_by = (['chrom', 'pos'] if target.type == 'bigquery' else none)) }}
-- Serving table for the API: one row per variant, with everything a lookup
-- returns. Clustered by chrom and pos on BigQuery, so a lookup by position (or
-- by variant_id, whose position the API parses first) reads a few blocks
-- instead of the table.
{% set pops = ['afr', 'amr', 'eas', 'eur', 'sas'] %}
with gnomad as (
    select
        variant_key,
        max(case when in_gnomad then 1 else 0 end) = 1 as in_gnomad,
        max(gnomad_filter) as gnomad_filter,
        max(gnomad_alleles_at_site) as gnomad_alleles_at_site,
        max(case when flagged then 1 else 0 end) = 1 as gnomad_af_discordant,
        {% for p in pops %}
        max(case when superpopulation = '{{ p | upper }}' then af_gnomad end) as gnomad_af_{{ p }}{{ ',' if not loop.last }}
        {% endfor %}
    from {{ ref('gnomad_concordance') }}
    group by variant_key
),

hwe as (
    select
        variant_key,
        max(case when hwe_departure then 1 else 0 end) = 1 as hwe_departure,
        {% for p in pops %}
        max(case when superpopulation = '{{ p | upper }}' then hwe_p_unrel end) as hwe_p_{{ p }}{{ ',' if not loop.last }}
        {% endfor %}
    from {{ ref('qc_hardy_weinberg') }}
    group by variant_key
)

select
    v.variant_key,
    v.variant_id,
    v.chrom,
    v.pos,
    v.end_pos,
    v.ref,
    v.alt,
    v.variant_class,
    v.sv_type,
    v.sv_len,
    v.ref_check,
    v.source_id,
    v.filter_status,
    v.gene_symbols,
    v.in_protein_coding_gene,
    c.region_class,
    c.in_segdup,
    c.in_low_mappability,
    c.in_tandem_repeat_or_homopolymer,
    c.in_any_difficult,
    f.af_from_unrelated,
    f.an_all,
    f.af_all,
    {% for p in pops %}
    f.af_{{ p }},
    {% endfor %}
    g.in_gnomad,
    g.gnomad_filter,
    g.gnomad_alleles_at_site,
    coalesce(g.gnomad_af_discordant, false) as gnomad_af_discordant,
    {% for p in pops %}
    g.gnomad_af_{{ p }},
    {% endfor %}
    coalesce(h.hwe_departure, false) as hwe_departure,
    {% for p in pops %}
    h.hwe_p_{{ p }},
    {% endfor %}
    v.in_clinvar,
    v.clinvar_variation_id,
    v.rsid,
    v.clinical_significance,
    v.clinvar_review_status,
    v.clinvar_conditions,
    v.clinvar_consequence,
    coalesce(k.common_but_pathogenic, false) as clinvar_common_but_pathogenic
from {{ ref('dim_variant') }} as v
join {{ ref('variant_context') }} as c on c.variant_key = v.variant_key
join {{ ref('variant_af_wide') }} as f on f.variant_key = v.variant_key
left join gnomad as g on g.variant_key = v.variant_key
left join hwe as h on h.variant_key = v.variant_key
left join {{ ref('clinvar_in_cohort') }} as k on k.variant_key = v.variant_key
