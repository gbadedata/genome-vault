select
    superpopulation,
    population,
    count(*) as n_samples,
    sum(case when is_unrelated then 1 else 0 end) as n_unrelated,
    sum(case when has_parents_in_cohort then 1 else 0 end) as n_with_parents_in_cohort
from {{ ref('dim_sample') }}
group by superpopulation, population
