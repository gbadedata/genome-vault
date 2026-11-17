-- gnomAD's BigQuery table stores 0-based start positions; VCF POS is 1-based.
-- Counting how many common 1000 Genomes SNVs (AF >= 1%) match gnomAD with each
-- convention shows which one is right on the data itself.
with common as (
    select v.chrom, v.pos, v.ref, v.alt
    from {{ ref('stg_kgp_variants') }} as v
    join {{ ref('variant_population_freq') }} as f using (variant_key)
    where f.superpopulation = 'ALL' and v.variant_class = 'SNV' and f.af >= 0.01
),

gnomad as (
    select
        case when chrom like 'chr%' then chrom else concat('chr', chrom) end as chrom,
        pos, start_position_0based, ref, alt
    from {{ ref('stg_gnomad') }}
)

select
    (select count(*) from common) as common_snvs,
    (select count(*) from common as c join gnomad as g
        on g.chrom = c.chrom and g.pos = c.pos and g.ref = c.ref and g.alt = c.alt) as matches_pos_plus_one,
    (select count(*) from common as c join gnomad as g
        on g.chrom = c.chrom and g.start_position_0based = c.pos and g.ref = c.ref and g.alt = c.alt) as matches_raw_start
