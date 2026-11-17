select gene_id, gene_symbol, biotype, chrom, gene_start, gene_end, strand, feature_type
from {{ source('raw', 'ensembl_genes') }}
