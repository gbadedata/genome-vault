{{ config(materialized = 'table') }}
-- Ensembl genes for the API: coordinates, how many loaded variants overlap
-- each gene, and the start of the first one. first_variant_pos lets the API
-- fetch a gene's variants with a position range on the clustered api_variant
-- table (a long deletion can start before the gene it overlaps).
with counts as (
    select b.gene_id, count(*) as variants, min(v.pos) as first_variant_pos
    from {{ ref('bridge_variant_gene') }} as b
    join {{ ref('stg_kgp_variants') }} as v on v.variant_key = b.variant_key
    group by b.gene_id
)

select
    g.gene_id,
    g.gene_symbol,
    g.biotype,
    g.chrom,
    g.gene_start,
    g.gene_end,
    g.strand,
    coalesce(c.variants, 0) as variants,
    c.first_variant_pos
from {{ ref('stg_genes') }} as g
left join counts as c on c.gene_id = g.gene_id
