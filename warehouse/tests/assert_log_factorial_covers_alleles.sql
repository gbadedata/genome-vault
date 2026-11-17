-- The exact HWE test looks up ln(k!) up to k = 2n; fail if the table is too small.
select max(n_samples) as largest_population
from {{ ref('variant_population_freq') }}
where superpopulation <> 'ALL'
having 2 * max(n_samples) > {{ var('max_alleles') }}
