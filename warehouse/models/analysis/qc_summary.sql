-- One row per check. 'invariant' checks must pass (the dbt tests enforce them);
-- 'finding' rows count what the analysis surfaced.
with runs as (
    select source, records_read, records_loaded, records_quarantined, genotype_rows from {{ ref('stg_load_runs') }}
),
kgp as (select * from runs where source = '1000G_30x_phased_panel'),
recon as (
    select
        sum(case when all_samples_match then 0 else 1 end) as all_mismatches,
        sum(case when unrelated_match is null then 0 when unrelated_match then 0 else 1 end) as unrel_mismatches,
        sum(case when unrelated_match is not null then 1 else 0 end) as unrel_compared,
        count(*) as compared
    from {{ ref('qc_allele_count_reconciliation') }}
),
offset_check as (select * from {{ ref('qc_gnomad_offset') }}),
difficult as (
    select
        finding,
        sum(case when region_class <> 'not_difficult' then with_finding else 0 end) as findings_in_difficult,
        sum(with_finding) as findings,
        sum(case when region_class <> 'not_difficult' then variants else 0 end) as variants_in_difficult,
        sum(variants) as variants
    from {{ ref('findings_by_region_class') }}
    group by finding
),
conc as (
    select
        sum(case when in_gnomad then 1 else 0 end) as in_gnomad,
        count(*) as compared,
        sum(case when flagged then 1 else 0 end) as flagged
    from {{ ref('gnomad_concordance') }}
)

select 'invariant' as kind, 'every 1000G record loaded or quarantined' as check_name,
       (select records_read from kgp) = (select records_loaded + records_quarantined from kgp) as passed,
       cast((select records_read from kgp) as {{ dbt.type_string() }}) as detail
union all
select 'invariant', 'variant rows equal records loaded',
       (select count(*) from {{ ref('stg_kgp_variants') }}) = (select records_loaded from kgp),
       cast((select count(*) from {{ ref('stg_kgp_variants') }}) as {{ dbt.type_string() }})
union all
select 'invariant', 'genotype rows equal loader count',
       (select count(*) from {{ ref('fct_genotype') }}) = (select genotype_rows from kgp),
       cast((select count(*) from {{ ref('fct_genotype') }}) as {{ dbt.type_string() }})
union all
select 'invariant', 'REF alleles match GRCh38',
       (select count(*) from {{ ref('stg_kgp_variants') }} where ref_check = 'mismatch') = 0,
       cast((select count(*) from {{ ref('stg_kgp_variants') }} where ref_check = 'match') as {{ dbt.type_string() }})
union all
select 'invariant', 'allele counts reproduce source (all samples)',
       (select all_mismatches from recon) = 0,
       cast((select compared from recon) as {{ dbt.type_string() }})
union all
select 'invariant', 'allele counts reproduce source (unrelated)',
       (select unrel_mismatches from recon) = 0 and (select unrel_compared from recon) > 0,
       cast((select unrel_compared from recon) as {{ dbt.type_string() }})
union all
select 'invariant', 'gnomAD positions are 0-based (+1 matches best)',
       (select matches_pos_plus_one from offset_check) > (select matches_raw_start from offset_check),
       concat(cast((select matches_pos_plus_one from offset_check) as {{ dbt.type_string() }}), ' vs ',
              cast((select matches_raw_start from offset_check) as {{ dbt.type_string() }}))
union all
select 'invariant', 'exact HWE test reproduces source HWE p-values',
       (select count(*) from {{ ref('qc_hardy_weinberg') }}
         where src_hwe_p is not null and abs(hwe_p_all - src_hwe_p) > 1e-4 * src_hwe_p + 1e-12) = 0,
       cast((select count(*) from {{ ref('qc_hardy_weinberg') }} where src_hwe_p is not null) as {{ dbt.type_string() }})
union all
select 'finding', 'variant-population pairs found in gnomAD', null,
       concat(cast((select in_gnomad from conc) as {{ dbt.type_string() }}), ' of ', cast((select compared from conc) as {{ dbt.type_string() }}))
union all
select 'finding', 'frequency differences flagged against gnomAD (variant-population pairs)', null,
       cast((select flagged from conc) as {{ dbt.type_string() }})
union all
select 'finding', 'HWE departures, exact p < threshold, unrelated (variant-population pairs)', null,
       cast((select count(*) from {{ ref('qc_hardy_weinberg') }} where hwe_departure) as {{ dbt.type_string() }})
union all
select 'finding', 'samples flagged by QC z-scores (within population; within superpopulation)', null,
       concat(cast((select count(*) from {{ ref('qc_sample') }} where flagged) as {{ dbt.type_string() }}), '; ',
              cast((select count(*) from {{ ref('qc_sample') }} where flagged_by_superpop) as {{ dbt.type_string() }}))
union all
select 'finding', 'ClinVar pathogenic calls common in a population', null,
       cast((select count(*) from {{ ref('clinvar_in_cohort') }} where common_but_pathogenic) as {{ dbt.type_string() }})
union all
select 'finding', concat('share in GIAB difficult regions: ', finding), null,
       concat(cast(round(100.0 * findings_in_difficult / nullif(findings, 0), 1) as {{ dbt.type_string() }}),
              '% of variants with the finding vs ',
              cast(round(100.0 * variants_in_difficult / nullif(variants, 0), 1) as {{ dbt.type_string() }}),
              '% of variants tested')
from difficult
