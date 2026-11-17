{{ config(cluster_by = (['gene_id'] if target.type == 'bigquery' else none)) }}
-- Which Ensembl genes each variant overlaps (many-to-many). Built once with a
-- windowed interval join: both sides are split into 100 kb windows and joined
-- on (chrom, window), then the exact overlap test runs within each window.
-- Joining on chromosome alone would compare every variant with every gene
-- (about 1.9 billion pairs on chr22, all on one join key).
{% set window = 100000 %}
with variant_windows as (
    select v.variant_key, v.chrom, v.pos, v.end_pos, w
    from {{ ref('stg_kgp_variants') }} as v
    {{ cross_join_series(window_of('v.pos', window), window_of('v.end_pos', window), 1, 'w') }}
),

gene_windows as (
    select g.gene_id, g.chrom, g.gene_start, g.gene_end, w
    from {{ ref('stg_genes') }} as g
    {{ cross_join_series(window_of('g.gene_start', window), window_of('g.gene_end', window), 1, 'w') }}
)

-- A long variant and a long gene can share several windows: keep each pair once.
select distinct vw.variant_key, gw.gene_id
from variant_windows as vw
join gene_windows as gw
    on gw.chrom = vw.chrom and gw.w = vw.w
    and gw.gene_start <= vw.end_pos and gw.gene_end >= vw.pos
