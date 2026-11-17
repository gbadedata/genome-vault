{{ config(materialized = 'table') }}
-- rsID to position, for the API's rsID lookups. The 1000 Genomes panel has no
-- rsIDs, so these are the ClinVar rsIDs of matched variants. A lookup reads
-- this small table first, then fetches the variant from its api_variant
-- partition, rather than scanning api_variant for an rsid.
select rsid, chrom, pos, variant_id
from {{ ref('api_variant') }}
where rsid is not null
