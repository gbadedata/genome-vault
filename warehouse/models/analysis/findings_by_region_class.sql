-- Do the warehouse's QC findings concentrate in GIAB difficult regions?
--
-- Each finding is counted once per variant (a variant flagged in two
-- populations counts once), and its rate in each region class is compared with
-- the rate in not_difficult regions:
--   hwe_departure                  exact HWE p < threshold in >= 1 superpopulation
--                                  (unrelated samples); SVs are not tested
--   gnomad_af_discordant           AF differs from gnomAD v3 by > threshold in
--                                  >= 1 superpopulation; variants found in gnomAD
--   common_but_absent_from_gnomad  AF >= var('common_af') in 1000 Genomes, yet no
--                                  gnomAD v3 record with the same chrom/pos/ref/alt
--
-- rate_ratio = rate in the class / rate in not_difficult, with a 95% interval
-- by the log method (Katz et al. 1978); null when either count is zero.
with events as (
    select 'hwe_departure' as finding, variant_key,
           max(case when hwe_departure then 1 else 0 end) as has_finding
    from {{ ref('qc_hardy_weinberg') }}
    group by variant_key

    union all

    select 'gnomad_af_discordant', variant_key,
           max(case when flagged then 1 else 0 end)
    from {{ ref('gnomad_concordance') }}
    where in_gnomad
    group by variant_key

    union all

    select 'common_but_absent_from_gnomad', c.variant_key,
           max(case when c.in_gnomad then 0 else 1 end)
    from {{ ref('gnomad_concordance') }} as c
    join {{ ref('variant_af_wide') }} as w on w.variant_key = c.variant_key
    where w.af_all >= {{ var('common_af') }}
    group by c.variant_key
),

by_class as (
    select
        e.finding,
        x.region_class,
        count(*) as variants,
        sum(e.has_finding) as with_finding
    from events as e
    join {{ ref('variant_context') }} as x on x.variant_key = e.variant_key
    group by e.finding, x.region_class
),

totals as (
    select finding, sum(variants) as all_variants, sum(with_finding) as all_with_finding
    from by_class
    group by finding
),

baseline as (
    select finding, variants as n0, with_finding as a0
    from by_class
    where region_class = 'not_difficult'
)

select
    b.finding,
    b.region_class,
    b.variants,
    b.with_finding,
    {{ safe_div('b.with_finding', 'b.variants') }} as rate,
    {{ safe_div('b.variants', 't.all_variants') }} as share_of_variants,
    {{ safe_div('b.with_finding', 't.all_with_finding') }} as share_of_findings,
    case when b.with_finding > 0 and z.a0 > 0
         then (cast(b.with_finding as {{ dbt.type_float() }}) / b.variants) / (cast(z.a0 as {{ dbt.type_float() }}) / z.n0)
    end as rate_ratio,
    case when b.with_finding > 0 and z.a0 > 0
         then exp(ln((cast(b.with_finding as {{ dbt.type_float() }}) / b.variants) / (cast(z.a0 as {{ dbt.type_float() }}) / z.n0))
                  - 1.96 * sqrt(1.0 / b.with_finding - 1.0 / b.variants + 1.0 / z.a0 - 1.0 / z.n0))
    end as rate_ratio_ci_low,
    case when b.with_finding > 0 and z.a0 > 0
         then exp(ln((cast(b.with_finding as {{ dbt.type_float() }}) / b.variants) / (cast(z.a0 as {{ dbt.type_float() }}) / z.n0))
                  + 1.96 * sqrt(1.0 / b.with_finding - 1.0 / b.variants + 1.0 / z.a0 - 1.0 / z.n0))
    end as rate_ratio_ci_high
from by_class as b
join totals as t on t.finding = b.finding
left join baseline as z on z.finding = b.finding
