select
    variant_id, chrom, pos, ref, alt, clinvar_variation_id, allele_id, rsid,
    clinical_significance, review_status, gene_symbols, conditions,
    molecular_consequence, variant_type, ref_check
from {{ source('raw', 'clinvar_variants') }}
