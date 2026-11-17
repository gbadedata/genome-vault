-- ClinVar drug-response variants in CYP2D6 observed in the cohort, with
-- frequencies by superpopulation. Caution: CYP2D6 sits next to two highly
-- similar genes (CYP2D7, CYP2D8P) and has common deletions, duplications and
-- hybrid alleles. Short-read calls here are less reliable than elsewhere, and
-- star-allele calling needs dedicated tools (for example Cyrius or Aldy).
select
    *,
    'CYP2D6 is flanked by the CYP2D7/CYP2D8P paralogs and has common structural variants; short-read SNV calls here need orthogonal confirmation before clinical use.' as caveat
from {{ ref('clinvar_in_cohort') }}
where is_drug_response and gene_symbols like '%CYP2D6%'
