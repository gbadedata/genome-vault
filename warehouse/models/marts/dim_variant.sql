-- One row per loaded 1000 Genomes variant, with the Ensembl genes it overlaps
-- and its ClinVar record (joined on chrom, pos, ref, alt: the panel has no rsIDs).
with genes as (
    select
        v.variant_key,
        string_agg(coalesce(g.gene_symbol, g.gene_id), '|' order by coalesce(g.gene_symbol, g.gene_id)) as gene_symbols,
        max(case when g.biotype = 'protein_coding' then 1 else 0 end) = 1 as in_protein_coding_gene
    from {{ ref('stg_kgp_variants') }} as v
    join {{ ref('stg_genes') }} as g
        on g.chrom = v.chrom and g.gene_start <= v.end_pos and g.gene_end >= v.pos
    group by v.variant_key
),

clinvar as (
    select *
    from {{ ref('stg_clinvar') }}
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
