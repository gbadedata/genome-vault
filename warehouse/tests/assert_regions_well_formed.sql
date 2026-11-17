-- Every stratification is present, intervals are valid, and merging left no
-- overlaps within a stratification.
with expected as (
    select 'segdup' as stratification union all select 'low_mappability'
    union all select 'tandem_repeat_homopolymer' union all select 'all_difficult'
),
missing as (
    select e.stratification, 'stratification missing' as problem
    from expected as e
    left join (select distinct stratification from {{ ref('stg_genome_regions') }}) as r using (stratification)
    where r.stratification is null
),
invalid as (
    select stratification, 'start >= end or negative start' as problem
    from {{ ref('stg_genome_regions') }}
    where start_0based < 0 or start_0based >= end_exclusive
),
overlapping as (
    select stratification, 'overlaps the previous interval' as problem
    from (
        select stratification, start_0based,
               lag(end_exclusive) over (partition by stratification, chrom order by start_0based) as prev_end
        from {{ ref('stg_genome_regions') }}
    ) as x
    where start_0based <= prev_end
)
select * from missing
union all select * from invalid
union all select * from overlapping
