-- Hardy-Weinberg equilibrium per variant and superpopulation, using the exact
-- test of Wigginton, Cutler and Abecasis (2005, AJHG 76:887-893).
--
-- Why not chi-square: most variants are rare, and the approximation fails
-- there. One homozygous carrier and no heterozygotes among 661 people gives
-- chi2 = 661 (p ~ 1e-145), while the exact p is 1/1321, about 0.0008.
--
-- hwe_p_all uses every sample in the population. That is how the source VCF
-- computed HWE_<POP>, so comparing the two validates this implementation.
-- hwe_p_unrel uses the 2,504 phase 3 unrelated samples and is the one to act
-- on: relatives are not independent draws, which the test assumes.
--
-- P(h hets | n people, n_minor minor alleles)
--   = n! n_ref! n_alt! 2^h / ( n_AA! h! n_BB! (2n)! )
-- p-value = sum of P(h) over every h no more likely than the observed one.
with counts as (
    select variant_key, variant_id, superpopulation, 'all' as sample_set,
           cast(n_samples - missing as {{ dbt.type_bigint() }}) as n,
           cast(het as {{ dbt.type_bigint() }}) as het,
           cast(hom_alt as {{ dbt.type_bigint() }}) as hom_alt
    from {{ ref('variant_population_freq') }}
    where superpopulation <> 'ALL' and variant_class <> 'SV'
    union all
    select variant_key, variant_id, superpopulation, 'unrelated' as sample_set,
           cast(n_unrelated - missing_unrel as {{ dbt.type_bigint() }}) as n,
           cast(het_unrel as {{ dbt.type_bigint() }}) as het,
           cast(hom_alt_unrel as {{ dbt.type_bigint() }}) as hom_alt
    from {{ ref('variant_population_freq') }}
    where superpopulation <> 'ALL' and variant_class <> 'SV' and n_unrelated > 0
),

alleles as (
    select
        *,
        n - het - hom_alt as hom_ref,
        2 * (n - het - hom_alt) + het as n_ref,
        het + 2 * hom_alt as n_alt,
        least(2 * (n - het - hom_alt) + het, het + 2 * hom_alt) as n_minor
    from counts
    where n > 0
),

with_const as (
    select
        a.*,
        f_n.ln_fact + f_ref.ln_fact + f_alt.ln_fact - f_2n.ln_fact as ln_const
    from alleles as a
    join {{ ref('util_log_factorial') }} as f_n on f_n.k = a.n
    join {{ ref('util_log_factorial') }} as f_ref on f_ref.k = a.n_ref
    join {{ ref('util_log_factorial') }} as f_alt on f_alt.k = a.n_alt
    join {{ ref('util_log_factorial') }} as f_2n on f_2n.k = 2 * a.n
),

-- Every possible het count with the same parity as n_minor.
expanded as (
    select
        c.variant_key, c.superpopulation, c.sample_set, c.n, c.het as het_obs, c.ln_const,
        h,
        cast((c.n_minor - h) / 2 as {{ dbt.type_bigint() }}) as n_minor_hom,
        c.n - h - cast((c.n_minor - h) / 2 as {{ dbt.type_bigint() }}) as n_major_hom
    from with_const as c
    {{ cross_join_series('mod(c.n_minor, 2)', 'c.n_minor', 2, 'h') }}
),

log_probs as (
    select
        e.variant_key, e.superpopulation, e.sample_set, e.h, e.het_obs,
        e.ln_const - f_maj.ln_fact - f_h.ln_fact - f_min.ln_fact + e.h * ln(2) as ln_p
    from expanded as e
    join {{ ref('util_log_factorial') }} as f_maj on f_maj.k = e.n_major_hom
    join {{ ref('util_log_factorial') }} as f_h on f_h.k = e.h
    join {{ ref('util_log_factorial') }} as f_min on f_min.k = e.n_minor_hom
),

with_obs as (
    select
        *,
        max(case when h = het_obs then ln_p end)
            over (partition by variant_key, superpopulation, sample_set) as ln_p_obs
    from log_probs
),

p_values as (
    select
        variant_key, superpopulation, sample_set,
        -- relative tolerance 1e-9 on the log scale, so ties count as no more likely
        least(1.0, sum(case when ln_p <= ln_p_obs + 1e-9 then exp(ln_p) else 0 end)) as hwe_p
    from with_obs
    group by variant_key, superpopulation, sample_set
),

unrel as (
    select * from alleles where sample_set = 'unrelated'
)

select
    u.variant_key,
    u.variant_id,
    v.variant_class,
    u.superpopulation,
    u.n,
    u.hom_ref,
    u.het,
    u.hom_alt,
    {{ safe_div('u.n_alt', '2 * u.n') }} as alt_allele_freq,
    -- expected hets = 2npq = n_ref * n_alt / 2n
    {{ safe_div('2 * u.n * u.het', 'u.n_ref * u.n_alt') }} as het_obs_over_exp,
    pu.hwe_p as hwe_p_unrel,
    pa.hwe_p as hwe_p_all,
    case u.superpopulation
        when 'AFR' then v.src_hwe_afr when 'AMR' then v.src_hwe_amr when 'EAS' then v.src_hwe_eas
        when 'EUR' then v.src_hwe_eur when 'SAS' then v.src_hwe_sas end as src_hwe_p,
    pu.hwe_p < {{ var('hwe_p_threshold') }} as hwe_departure
from unrel as u
join p_values as pu
    on pu.variant_key = u.variant_key and pu.superpopulation = u.superpopulation and pu.sample_set = 'unrelated'
left join p_values as pa
    on pa.variant_key = u.variant_key and pa.superpopulation = u.superpopulation and pa.sample_set = 'all'
join {{ ref('stg_kgp_variants') }} as v on v.variant_key = u.variant_key
