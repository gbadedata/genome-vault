-- GIAB's "all difficult regions" union should contain the component
-- stratifications. Fails if more than 1% of variants flagged in a segmental
-- duplication, low-mappability region or tandem repeat sit outside the union,
-- which would point at a join or coordinate bug.
select
    count(*) as flagged_in_a_component,
    sum(case when in_any_difficult then 0 else 1 end) as outside_union
from {{ ref('variant_context') }}
where in_segdup or in_low_mappability or in_tandem_repeat_or_homopolymer
having sum(case when in_any_difficult then 0 else 1 end) > 0.01 * count(*)
