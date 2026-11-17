-- One row per variant with allele frequency per superpopulation. Uses the
-- unrelated phase 3 samples when that panel was loaded (population frequency
-- estimates should not count relatives twice), all samples otherwise.
with panel as (
    select max(case when in_phase3_unrelated is not null then 1 else 0 end) = 1 as loaded
    from {{ ref('dim_sample') }}
),

f as (
    select
        f.variant_key,
        f.superpopulation,
        case when panel.loaded then f.af_unrel else f.af end as af,
        case when panel.loaded then f.an_unrel else f.an end as an,
        panel.loaded as from_unrelated
    from {{ ref('variant_population_freq') }} as f
    cross join panel
)

select
    variant_key,
    max(from_unrelated) as af_from_unrelated,
    max(case when superpopulation = 'ALL' then af end) as af_all,
    max(case when superpopulation = 'AFR' then af end) as af_afr,
    max(case when superpopulation = 'AMR' then af end) as af_amr,
    max(case when superpopulation = 'EAS' then af end) as af_eas,
    max(case when superpopulation = 'EUR' then af end) as af_eur,
    max(case when superpopulation = 'SAS' then af end) as af_sas,
    max(case when superpopulation = 'ALL' then an end) as an_all
from f
group by variant_key
