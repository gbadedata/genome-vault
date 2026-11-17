{{ config(cluster_by = ['region_class'] if target.type == 'bigquery' else none) }}
-- Genomic context of every variant, from the Genome in a Bottle (NIST) GRCh38
-- stratifications: is it in a segmental duplication, a low-mappability region,
-- a tandem repeat or homopolymer, or any GIAB difficult region?
--
-- region_class gives each variant exactly one class, in this order of
-- precedence: segmental_duplication, low_mappability,
-- tandem_repeat_or_homopolymer, other_difficult, not_difficult. The flags keep
-- the overlaps (a duplicated region is usually also low-mappability).
--
-- A BED interval [start_0based, end_exclusive) covers 1-based positions
-- start_0based + 1 .. end_exclusive. It overlaps a variant spanning pos..end_pos
-- when start_0based < end_pos and end_exclusive >= pos. Both sides are split
-- into 10 kb windows first so the interval join stays an equi-join.
{% set window = 10000 %}
with variant_windows as (
    select v.variant_key, v.chrom, v.pos, v.end_pos, w
    from {{ ref('stg_kgp_variants') }} as v
    {{ cross_join_series(window_of('v.pos', window), window_of('v.end_pos', window), 1, 'w') }}
),

region_windows as (
    select r.stratification, r.chrom, r.start_0based, r.end_exclusive, w
    from {{ ref('stg_genome_regions') }} as r
    {{ cross_join_series(window_of('r.start_0based + 1', window), window_of('r.end_exclusive', window), 1, 'w') }}
),

hits as (
    select distinct vw.variant_key, rw.stratification
    from variant_windows as vw
    join region_windows as rw
        on rw.chrom = vw.chrom and rw.w = vw.w
        and rw.start_0based < vw.end_pos and rw.end_exclusive >= vw.pos
),

flags as (
    select
        variant_key,
        max(case when stratification = 'segdup' then 1 else 0 end) = 1 as in_segdup,
        max(case when stratification = 'low_mappability' then 1 else 0 end) = 1 as in_low_mappability,
        max(case when stratification = 'tandem_repeat_homopolymer' then 1 else 0 end) = 1 as in_tandem_repeat_or_homopolymer,
        max(case when stratification = 'all_difficult' then 1 else 0 end) = 1 as in_any_difficult
    from hits
    group by variant_key
)

select
    v.variant_key,
    coalesce(f.in_segdup, false) as in_segdup,
    coalesce(f.in_low_mappability, false) as in_low_mappability,
    coalesce(f.in_tandem_repeat_or_homopolymer, false) as in_tandem_repeat_or_homopolymer,
    coalesce(f.in_any_difficult, false) as in_any_difficult,
    case
        when coalesce(f.in_segdup, false) then 'segmental_duplication'
        when coalesce(f.in_low_mappability, false) then 'low_mappability'
        when coalesce(f.in_tandem_repeat_or_homopolymer, false) then 'tandem_repeat_or_homopolymer'
        when coalesce(f.in_any_difficult, false) then 'other_difficult'
        else 'not_difficult'
    end as region_class
from {{ ref('stg_kgp_variants') }} as v
left join flags as f using (variant_key)
