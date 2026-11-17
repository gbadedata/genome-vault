-- Our allele counts (from 3,202 genotypes) against the counts the source wrote
-- into INFO, per variant and population. Unrelated counts are compared only
-- when the phase 3 panel was loaded.
with src as (
    select
        f.*,
        case f.superpopulation
            when 'ALL' then v.src_ac when 'AFR' then v.src_ac_afr when 'AMR' then v.src_ac_amr
            when 'EAS' then v.src_ac_eas when 'EUR' then v.src_ac_eur when 'SAS' then v.src_ac_sas end as src_ac,
        case f.superpopulation
            when 'ALL' then v.src_an when 'AFR' then v.src_an_afr when 'AMR' then v.src_an_amr
            when 'EAS' then v.src_an_eas when 'EUR' then v.src_an_eur when 'SAS' then v.src_an_sas end as src_an,
        case f.superpopulation
            when 'AFR' then v.src_ac_afr_unrel when 'AMR' then v.src_ac_amr_unrel when 'EAS' then v.src_ac_eas_unrel
            when 'EUR' then v.src_ac_eur_unrel when 'SAS' then v.src_ac_sas_unrel end as src_ac_unrel,
        case f.superpopulation
            when 'AFR' then v.src_an_afr_unrel when 'AMR' then v.src_an_amr_unrel when 'EAS' then v.src_an_eas_unrel
            when 'EUR' then v.src_an_eur_unrel when 'SAS' then v.src_an_sas_unrel end as src_an_unrel
    from {{ ref('variant_population_freq') }} as f
    join {{ ref('stg_kgp_variants') }} as v using (variant_key)
),

panel as (
    select max(case when in_phase3_unrelated is not null then 1 else 0 end) = 1 as loaded
    from {{ ref('dim_sample') }}
)

select
    variant_key,
    variant_id,
    variant_class,
    superpopulation,
    ac, src_ac, an, src_an,
    ac_unrel, src_ac_unrel, an_unrel, src_an_unrel,
    (ac = src_ac and an = src_an) as all_samples_match,
    case
        when not panel.loaded or superpopulation = 'ALL' then null
        else (ac_unrel = src_ac_unrel and an_unrel = src_an_unrel)
    end as unrelated_match
from src
cross join panel
