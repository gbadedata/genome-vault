-- Fails (returns rows) if any invariant in qc_summary did not pass.
select * from {{ ref('qc_summary') }} where kind = 'invariant' and not passed
