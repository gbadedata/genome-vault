"""The API's SQL. {t} is the table prefix and @name a bound parameter; values
never reach the SQL text. Every api_variant query filters on pos directly (no
function around it), so BigQuery prunes the table's integer-range partitions
and its pre-run estimate stays under the per-query byte cap."""

VARIANT_BY_ID = """
select * from {t}api_variant
where chrom = @chrom and pos = @pos and variant_id = @variant_id
"""

VARIANTS_IN_REGION = """
select * from {t}api_variant
where chrom = @chrom and pos between @start and @end
  and (@flagged_only = false or hwe_departure or gnomad_af_discordant)
order by pos, variant_id
limit @limit
"""

RSID_POSITIONS = """
select chrom, pos, variant_id from {t}api_rsid
where rsid = @rsid
order by pos
limit 20
"""

VARIANTS_AT_POSITIONS = """
select * from {t}api_variant
where chrom = @chrom and pos between @first_pos and @last_pos and rsid = @rsid
order by pos
"""

GENE_BY_SYMBOL = """
select * from {t}api_gene
where upper(gene_symbol) = upper(@symbol)
order by gene_start
"""

# first_variant_pos lower-bounds the scan: a long deletion can start before
# the gene it overlaps. end_pos >= gene_start makes the overlap exact.
VARIANTS_IN_GENE = """
select * from {t}api_variant
where chrom = @chrom and pos between @first_pos and @gene_end and end_pos >= @gene_start
order by pos, variant_id
limit @limit
"""

SAMPLE = """
select s.sample_id, s.population, s.superpopulation, s.sex, s.family_id, s.father_id, s.mother_id,
       s.has_parents_in_cohort, s.in_phase3_unrelated,
       q.snv_non_ref_sites, q.snv_het, q.snv_hom_alt, q.ti_tv, q.het_hom_ratio,
       q.ti_tv_z, q.het_hom_z, q.non_ref_z, q.ti_tv_z_superpop, q.het_hom_z_superpop, q.non_ref_z_superpop,
       q.flagged, q.flagged_by_superpop
from {t}dim_sample as s
join {t}qc_sample as q on q.sample_index = s.sample_index
where s.sample_id = @sample_id
"""

QC_SUMMARY = """
select kind, check_name, passed, detail from {t}qc_summary
order by kind desc, check_name
"""

FINDINGS_BY_REGION = """
select * from {t}findings_by_region_class
order by finding, region_class
"""
