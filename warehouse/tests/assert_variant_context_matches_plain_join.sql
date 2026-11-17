-- variant_context finds overlaps through 10 kb windows. Over the development
-- region (chr22:42,050,000-42,250,000, present in both the slice and the full
-- build) this recomputes the flags with a plain range join, no windows, and
-- returns any variant where the two disagree. The overlap rule itself was
-- also checked independently in Python on all 5,452 slice variants.
with v as (
    select variant_key, chrom, pos, end_pos
    from {{ ref('stg_kgp_variants') }}
    where pos between 42050000 and 42250000
),

r as (
    select stratification, chrom, start_0based, end_exclusive
    from {{ ref('stg_genome_regions') }}
    where end_exclusive >= 42050000 and start_0based < 42250000
),

plain as (
    select
        v.variant_key,
        max(case when r.stratification = 'segdup' then 1 else 0 end) = 1 as in_segdup,
        max(case when r.stratification = 'low_mappability' then 1 else 0 end) = 1 as in_low_mappability,
        max(case when r.stratification = 'tandem_repeat_homopolymer' then 1 else 0 end) = 1 as in_tandem_repeat_or_homopolymer,
        max(case when r.stratification = 'all_difficult' then 1 else 0 end) = 1 as in_any_difficult
    from v
    left join r
        on r.chrom = v.chrom and r.start_0based < v.end_pos and r.end_exclusive >= v.pos
    group by v.variant_key
)

select p.*
from plain as p
join {{ ref('variant_context') }} as c on c.variant_key = p.variant_key
where p.in_segdup <> c.in_segdup
   or p.in_low_mappability <> c.in_low_mappability
   or p.in_tandem_repeat_or_homopolymer <> c.in_tandem_repeat_or_homopolymer
   or p.in_any_difficult <> c.in_any_difficult
