-- One row per loaded 1000 Genomes variant, with the Ensembl genes it overlaps
-- and its ClinVar record (joined on chrom, pos, ref, alt: the panel has no rsIDs).
--
-- Gene overlap is an interval join. Joining on chromosome alone compares every
-- variant with every gene (about 1.9 billion pairs on chr22, all on one join
-- key), so both sides are first split into 100 kb windows and joined on
-- (chrom, window); the exact overlap test then runs within each window.
{% set window = 100000 %}
with variant_windows as (
    select v.variant_key, v.chrom, v.pos, v.end_pos, w
    from {{ ref('stg_kgp_variants') }} as v
    {{ cross_join_series(window_of('v.pos', window), window_of('v.end_pos', window), 1, 'w') }}
),

gene_windows as (
    select g.gene_id, g.gene_symbol, g.biotype, g.chrom, g.gene_start, g.gene_end, w
    from {{ ref('stg_genes') }} as g
    {{ cross_join_series(window_of('g.gene_start', window), window_of('g.gene_end', window), 1, 'w') }}
),

-- A long variant and a long gene can share several windows: keep each pair once.
variant_gene_pairs as (
    select distinct vw.variant_key, gw.gene_id, gw.gene_symbol, gw.biotype
    from variant_windows as vw
    join gene_windows as gw
        on gw.chrom = vw.chrom and gw.w = vw.w
        and gw.gene_start <= vw.end_pos and gw.gene_end >= vw.pos
),

genes as (
    select
        variant_key,
        string_agg(coalesce(gene_symbol, gene_id), '|' order by coalesce(gene_symbol, gene_id)) as gene_symbols,
        max(case when biotype = 'protein_coding' then 1 else 0 end) = 1 as in_protein_coding_gene
    from variant_gene_pairs
    group by variant_key
),

clinvar as (
    select *
    from {{ ref('stg_clinvar') }}
    where true  -- BigQuery has required WHERE, GROUP BY or HAVING alongside QUALIFY
    qualify row_number() over (partition by variant_id order by clinvar_variation_id) = 1
)

select
    v.variant_key,
    v.variant_id,
    v.chrom,
    v.pos,
    v.end_pos,
    v.ref,
    v.alt,
    v.variant_class,
    v.sv_type,
    v.sv_len,
    v.is_transition,
    v.ref_check,
    v.source_id,
    v.filter_status,
    g.gene_symbols,
    coalesce(g.in_protein_coding_gene, false) as in_protein_coding_gene,
    c.variant_id is not null as in_clinvar,
    c.clinvar_variation_id,
    c.rsid,
    c.clinical_significance,
    c.review_status as clinvar_review_status,
    c.conditions as clinvar_conditions,
    c.molecular_consequence as clinvar_consequence
from {{ ref('stg_kgp_variants') }} as v
left join genes as g using (variant_key)
left join clinvar as c using (variant_id)
