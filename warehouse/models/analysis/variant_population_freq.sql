-- Allele counts and frequencies per variant and superpopulation (plus ALL),
-- recomputed from the genotypes, for all samples and for the unrelated set.
with pops as (
    select superpopulation, count(*) as n_samples, sum(case when is_unrelated then 1 else 0 end) as n_unrelated
    from {{ ref('dim_sample') }}
    group by superpopulation
    union all
    select 'ALL', count(*), sum(case when is_unrelated then 1 else 0 end)
    from {{ ref('dim_sample') }}
),

by_pop as (
    select
        variant_key,
        superpopulation,
        sum(case when gt = 1 then 1 else 0 end) as het,
        sum(case when gt = 2 then 1 else 0 end) as hom_alt,
        sum(case when gt = -1 then 1 else 0 end) as missing,
        sum(case when gt = 1 and is_unrelated then 1 else 0 end) as het_unrel,
        sum(case when gt = 2 and is_unrelated then 1 else 0 end) as hom_alt_unrel,
        sum(case when gt = -1 and is_unrelated then 1 else 0 end) as missing_unrel
    from {{ ref('fct_genotype') }}
    group by variant_key, superpopulation
),

calls as (
    select * from by_pop
    union all
    select variant_key, 'ALL', sum(het), sum(hom_alt), sum(missing), sum(het_unrel), sum(hom_alt_unrel), sum(missing_unrel)
    from by_pop
    group by variant_key
),

counts as (
    select
        v.variant_key,
        v.variant_id,
        v.variant_class,
        p.superpopulation,
        p.n_samples,
        p.n_unrelated,
        coalesce(c.het, 0) as het,
        coalesce(c.hom_alt, 0) as hom_alt,
        coalesce(c.missing, 0) as missing,
        coalesce(c.het_unrel, 0) as het_unrel,
        coalesce(c.hom_alt_unrel, 0) as hom_alt_unrel,
        coalesce(c.missing_unrel, 0) as missing_unrel
    from {{ ref('stg_kgp_variants') }} as v
    cross join pops as p
    left join calls as c
        on c.variant_key = v.variant_key and c.superpopulation = p.superpopulation
)

select
    *,
    het + 2 * hom_alt as ac,
    2 * (n_samples - missing) as an,
    {{ safe_div('het + 2 * hom_alt', '2 * (n_samples - missing)') }} as af,
    het_unrel + 2 * hom_alt_unrel as ac_unrel,
    2 * (n_unrelated - missing_unrel) as an_unrel,
    {{ safe_div('het_unrel + 2 * hom_alt_unrel', '2 * (n_unrelated - missing_unrel)') }} as af_unrel
from counts
