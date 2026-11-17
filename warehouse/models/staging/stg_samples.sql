-- VCF column order joined to the pedigree/population table.
select
    v.sample_index,
    v.sample_id,
    s.family_id,
    s.father_id,
    s.mother_id,
    s.sex,
    s.population,
    s.superpopulation,
    s.has_parents_in_cohort,
    s.in_phase3_unrelated
from {{ source('raw', 'kgp_samples_vcf') }} as v
left join {{ source('raw', 'kgp_samples') }} as s using (sample_id)
