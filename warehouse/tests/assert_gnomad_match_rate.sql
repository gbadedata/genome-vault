-- Common SNVs in 1000 Genomes should almost all be in gnomAD v3 (76,156 genomes).
-- Fails below 90%, which would point at a join or coordinate bug.
select * from {{ ref('qc_gnomad_offset') }}
where common_snvs = 0 or cast(matches_pos_plus_one as {{ float_type() }}) / common_snvs < 0.90
