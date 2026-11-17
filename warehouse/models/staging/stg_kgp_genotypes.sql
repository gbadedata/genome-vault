select variant_key, sample_index, gt, phased
from {{ source('raw', 'kgp_genotypes') }}
