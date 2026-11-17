-- ClinVar records seen in the 1000 Genomes cohort, with population frequencies.
-- A variant classed pathogenic that is common (>= var('common_af')) in a
-- healthy reference population is a known signal of over-classification, or of
-- a recessive or low-penetrance allele: worth a reviewer's look, not a verdict.
with wide as (
    select
        d.variant_key, d.variant_id, d.rsid, d.gene_symbols, d.clinical_significance, d.clinvar_review_status,
        d.clinvar_conditions, d.clinvar_consequence, d.variant_class,
        w.af_from_unrelated, w.af_all, w.af_afr, w.af_amr, w.af_eas, w.af_eur, w.af_sas,
        greatest(coalesce(w.af_afr, 0), coalesce(w.af_amr, 0), coalesce(w.af_eas, 0),
                 coalesce(w.af_eur, 0), coalesce(w.af_sas, 0)) as max_pop_af
    from {{ ref('dim_variant') }} as d
    join {{ ref('variant_af_wide') }} as w using (variant_key)
    where d.in_clinvar
)

select
    *,
    case max_pop_af
        when coalesce(af_afr, 0) then 'AFR' when coalesce(af_amr, 0) then 'AMR'
        when coalesce(af_eas, 0) then 'EAS' when coalesce(af_eur, 0) then 'EUR' else 'SAS' end as max_pop,
    (lower(clinical_significance) like '%pathogenic%'
        and lower(clinical_significance) not like '%conflicting%'
        and max_pop_af >= {{ var('common_af') }}) as common_but_pathogenic,
    lower(clinical_significance) like '%drug_response%' as is_drug_response
from wide
