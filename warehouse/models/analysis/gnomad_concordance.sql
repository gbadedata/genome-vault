-- 1000 Genomes allele frequencies (recomputed here) against gnomAD v3 genomes,
-- per superpopulation. gnomAD's non-Finnish Europeans (nfe) stand in for EUR.
-- Flags differences above var('af_diff_threshold') where both sides called at
-- least var('min_an') alleles: candidates for genotyping artefacts, or real
-- differences between the two cohorts' sampling. gnomad_alleles_at_site counts
-- the alleles gnomAD reports at the same position; a high count marks a
-- repeat or homopolymer where callers often disagree on representation.
with ours as (
    select f.variant_key, f.variant_id, v.chrom, v.pos, v.ref, v.alt, v.variant_class, f.superpopulation,
           f.af_unrel, f.an_unrel, f.af, f.an
    from {{ ref('variant_population_freq') }} as f
    join {{ ref('stg_kgp_variants') }} as v using (variant_key)
    where f.superpopulation <> 'ALL' and v.variant_class <> 'SV'
),

panel as (
    select max(case when in_phase3_unrelated is not null then 1 else 0 end) = 1 as loaded
    from {{ ref('dim_sample') }}
),

gnomad as (
    select
        case when chrom like 'chr%' then chrom else concat('chr', chrom) end as chrom,
        pos, ref, alt, filter_status,
        af_afr, an_afr, af_amr, an_amr, af_eas, an_eas, af_nfe, an_nfe, af_sas, an_sas
    from {{ ref('stg_gnomad') }}
),

site_complexity as (
    select chrom, pos, count(*) as gnomad_alleles_at_site
    from gnomad
    group by chrom, pos
),

joined as (
    select
        o.variant_key, o.variant_id, o.variant_class, o.superpopulation,
        case when panel.loaded then o.af_unrel else o.af end as af_1kg,
        case when panel.loaded then o.an_unrel else o.an end as an_1kg,
        g.pos is not null as in_gnomad,
        sc.gnomad_alleles_at_site,
        g.filter_status as gnomad_filter,
        case o.superpopulation when 'AFR' then g.af_afr when 'AMR' then g.af_amr when 'EAS' then g.af_eas
                               when 'EUR' then g.af_nfe when 'SAS' then g.af_sas end as af_gnomad,
        case o.superpopulation when 'AFR' then g.an_afr when 'AMR' then g.an_amr when 'EAS' then g.an_eas
                               when 'EUR' then g.an_nfe when 'SAS' then g.an_sas end as an_gnomad
    from ours as o
    cross join panel
    left join gnomad as g
        on g.chrom = o.chrom and g.pos = o.pos and g.ref = o.ref and g.alt = o.alt
    left join site_complexity as sc
        on sc.chrom = o.chrom and sc.pos = o.pos
)

select
    *,
    af_1kg - af_gnomad as af_diff,
    (in_gnomad
        and an_1kg >= {{ var('min_an') }} and an_gnomad >= {{ var('min_an') }}
        and abs(af_1kg - af_gnomad) > {{ var('af_diff_threshold') }}) as flagged
from joined
