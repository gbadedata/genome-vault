-- ln(k!) for k = 0..var('max_alleles'), as a running sum of ln(k).
-- BigQuery has no lgamma(), so the exact HWE test looks factorials up here.
select
    k,
    sum(ln(greatest(k, 1))) over (order by k rows between unbounded preceding and current row) as ln_fact
from {{ int_series(var('max_alleles')) }} as series
