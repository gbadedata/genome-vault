{{ config(cluster_by = ['variant_key'] if target.type == 'bigquery' else none) }}
-- Sparse genotype fact: one row per non-reference (or missing) call.
-- Hom-ref calls are implied; allele numbers come from sample counts.
select
    g.variant_key,
    g.sample_index,
    s.superpopulation,
    s.is_unrelated,
    g.gt,
    g.phased
from {{ ref('stg_kgp_genotypes') }} as g
join {{ ref('dim_sample') }} as s using (sample_index)
