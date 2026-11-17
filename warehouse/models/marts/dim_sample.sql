-- One row per sample in the VCF. is_unrelated is the phase 3 set of 2,504:
-- having no parents in the cohort is not enough (siblings and other relatives
-- have none either), and the source's *_unrel counts use the phase 3 set.
select
    sample_index,
    sample_id,
    family_id,
    father_id,
    mother_id,
    sex,
    population,
    superpopulation,
    has_parents_in_cohort,
    in_phase3_unrelated,
    coalesce(in_phase3_unrelated, false) as is_unrelated
from {{ ref('stg_samples') }}
