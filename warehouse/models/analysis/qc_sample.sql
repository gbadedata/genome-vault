-- Per-sample QC over SNVs: transitions/transversions, het/hom-alt ratio and
-- the number of non-reference sites, each as a z-score within the sample's
-- population (26 groups). |z| > 4 on any metric is flagged for review.
--
-- Why population, not superpopulation: scored against the five
-- superpopulations, the full chr22 build flagged 27 samples, and they traced to
-- ancestry, not data quality. 14 were in the admixed ASW, ACB and PUR
-- populations, whose mixed ancestry moves these counts away from the
-- superpopulation mean; most of the rest had a heterozygosity deficit
-- typical of their population. The superpopulation z-scores are kept
-- (*_z_superpop) so the two can be compared. On a small region the ratios are
-- noisy, so flags are informational.
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
        {% for metric, col in [('ti_tv', 'ti_tv'), ('het_hom_ratio', 'het_hom'), ('snv_non_ref_sites', 'non_ref')] %}
        {{ safe_div(metric ~ ' - avg(' ~ metric ~ ') over (partition by population)', 'stddev_samp(' ~ metric ~ ') over (partition by population)') }} as {{ col }}_z,
        {{ safe_div(metric ~ ' - avg(' ~ metric ~ ') over (partition by superpopulation)', 'stddev_samp(' ~ metric ~ ') over (partition by superpopulation)') }} as {{ col }}_z_superpop{{ ',' if not loop.last }}
        {% endfor %}
    from ratios
)

select
    *,
    (abs(coalesce(ti_tv_z, 0)) > 4 or abs(coalesce(het_hom_z, 0)) > 4 or abs(coalesce(non_ref_z, 0)) > 4) as flagged,
    (abs(coalesce(ti_tv_z_superpop, 0)) > 4 or abs(coalesce(het_hom_z_superpop, 0)) > 4
        or abs(coalesce(non_ref_z_superpop, 0)) > 4) as flagged_by_superpop
from z
