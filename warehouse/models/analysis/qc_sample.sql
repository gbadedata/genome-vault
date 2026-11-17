-- Per-sample QC over SNVs: transitions/transversions and het/hom-alt ratio,
-- with z-scores within each superpopulation. |z| > 4 is flagged for review;
-- on a small region these ratios are noisy, so flags are informational.
with per_sample as (
    select
        g.sample_index,
        sum(case when v.is_transition then 1 else 0 end) as transitions,
        sum(case when not v.is_transition then 1 else 0 end) as transversions,
        sum(case when g.gt = 1 then 1 else 0 end) as snv_het,
        sum(case when g.gt = 2 then 1 else 0 end) as snv_hom_alt,
        count(*) as snv_non_ref_sites
    from {{ ref('fct_genotype') }} as g
    join {{ ref('stg_kgp_variants') }} as v using (variant_key)
    where v.variant_class = 'SNV' and g.gt in (1, 2)
    group by g.sample_index
),

ratios as (
    select
        s.sample_index, s.sample_id, s.population, s.superpopulation, s.sex, s.is_unrelated,
        p.transitions, p.transversions, p.snv_het, p.snv_hom_alt, p.snv_non_ref_sites,
        {{ safe_div('p.transitions', 'p.transversions') }} as ti_tv,
        {{ safe_div('p.snv_het', 'p.snv_hom_alt') }} as het_hom_ratio
    from {{ ref('dim_sample') }} as s
    left join per_sample as p using (sample_index)
),

z as (
    select
        *,
        {{ safe_div('ti_tv - avg(ti_tv) over (partition by superpopulation)', 'stddev_samp(ti_tv) over (partition by superpopulation)') }} as ti_tv_z,
        {{ safe_div('het_hom_ratio - avg(het_hom_ratio) over (partition by superpopulation)', 'stddev_samp(het_hom_ratio) over (partition by superpopulation)') }} as het_hom_z,
        {{ safe_div('snv_non_ref_sites - avg(snv_non_ref_sites) over (partition by superpopulation)', 'stddev_samp(snv_non_ref_sites) over (partition by superpopulation)') }} as non_ref_z
    from ratios
)

select
    *,
    (abs(coalesce(ti_tv_z, 0)) > 4 or abs(coalesce(het_hom_z, 0)) > 4 or abs(coalesce(non_ref_z, 0)) > 4) as flagged
from z
