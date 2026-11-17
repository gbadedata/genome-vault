# BigQuery build on full chromosome 22 (2026-11-17T21:49:58+00:00)

Project `genome-vault-202605`, dataset `gv`, location US, code version `c5e9666`.

## Load

Run `20261117T212537Z` from `gs://genome-vault-202605-gv-data/runs/20261117T212537Z/parquet`.

| Table | Parquet rows | BigQuery rows |
|---|---:|---:|
| clinvar_quarantine | 52 | 52 |
| clinvar_variants | 99,961 | 99,961 |
| ensembl_genes | 1,747 | 1,747 |
| genome_region_sources | 4 | 4 |
| genome_regions | 124,292 | 124,292 |
| kgp_genotypes | 207,523,964 | 207,523,964 |
| kgp_quarantine | 0 | 0 |
| kgp_samples | 3,202 | 3,202 |
| kgp_samples_vcf | 3,202 | 3,202 |
| kgp_variants | 1,066,557 | 1,066,557 |
| load_runs | 4 | 4 |

## dbt build

Statuses: {'success': 26, 'pass': 30}, 74.6 s, dbt 1.13.0b1.


## QC summary

| Kind | Check | Passed | Detail |
|---|---|---|---|
| finding | frequency differences flagged against gnomAD (variant-population pairs) | None | 1718 |
| finding | ClinVar pathogenic calls common in a population | None | 2 |
| finding | share in GIAB difficult regions: common_but_absent_from_gnomad | None | 99.7% of variants with the finding vs 45% of variants tested |
| finding | variant-population pairs found in gnomAD | None | 4892150 of 5325475 |
| finding | samples flagged by QC z-scores (within population; within superpopulation) | None | 15; 27 |
| finding | share in GIAB difficult regions: gnomad_af_discordant | None | 94.9% of variants with the finding vs 41.7% of variants tested |
| finding | share in GIAB difficult regions: hwe_departure | None | 93.6% of variants with the finding vs 40.9% of variants tested |
| finding | HWE departures, exact p < threshold, unrelated (variant-population pairs) | None | 11345 |
| invariant | genotype rows equal loader count | True | 207523964 |
| invariant | every 1000G record loaded or quarantined | True | 1066557 |
| invariant | allele counts reproduce source (unrelated) | True | 5332785 |
| invariant | allele counts reproduce source (all samples) | True | 6399342 |
| invariant | exact HWE test reproduces source HWE p-values | True | 5325475 |
| invariant | REF alleles match GRCh38 | True | 1066557 |
| invariant | variant rows equal records loaded | True | 1066557 |
| invariant | gnomAD positions are 0-based (+1 matches best) | True | 190739 vs 7609 |

## Cost

56 queries; 26.373 GB processed, 26.539 GB billed; largest single query 5.188 GB (cap 20 GB).

## Findings by GIAB region class

Rate of each finding per variant, and its ratio to the rate in not-difficult regions (95% interval).

| Finding | Region class | Variants | With finding | Rate | Ratio | 95% low | 95% high |
|---|---|---|---|---|---|---|---|
| common_but_absent_from_gnomad | tandem_repeat_or_homopolymer | 53,667 | 276 | 0.00514 | 680 | 95.5 | 4,846 |
| common_but_absent_from_gnomad | segmental_duplication | 37,490 | 25 | 0.000667 | 88.2 | 12 | 651 |
| common_but_absent_from_gnomad | low_mappability | 5,538 | 2 | 0.000361 | 47.8 | 4.33 | 527 |
| common_but_absent_from_gnomad | not_difficult | 132,271 | 1 | 7.56e-06 | 1 | 0.0625 | 16 |
| common_but_absent_from_gnomad | other_difficult | 11,494 | 0 | 0 |  |  |  |
| gnomad_af_discordant | tandem_repeat_or_homopolymer | 153,094 | 700 | 0.00457 | 55.5 | 41.3 | 74.5 |
| gnomad_af_discordant | segmental_duplication | 174,400 | 147 | 0.000843 | 10.2 | 7.36 | 14.2 |
| gnomad_af_discordant | low_mappability | 28,231 | 20 | 0.000708 | 8.59 | 5.09 | 14.5 |
| gnomad_af_discordant | other_difficult | 52,499 | 11 | 0.00021 | 2.54 | 1.32 | 4.9 |
| gnomad_af_discordant | not_difficult | 570,206 | 47 | 8.24e-05 | 1 | 0.667 | 1.5 |
| hwe_departure | segmental_duplication | 187,563 | 4,220 | 0.0225 | 35 | 31.6 | 38.7 |
| hwe_departure | low_mappability | 30,093 | 484 | 0.0161 | 25 | 21.9 | 28.5 |
| hwe_departure | tandem_repeat_or_homopolymer | 160,316 | 1,246 | 0.00777 | 12.1 | 10.8 | 13.5 |
| hwe_departure | not_difficult | 629,374 | 405 | 0.000643 | 1 | 0.871 | 1.15 |
| hwe_departure | other_difficult | 57,749 | 13 | 0.000225 | 0.35 | 0.201 | 0.608 |

Variants by region class:

| Region class | Variants |
|---|---|
| not_difficult | 629,783 |
| segmental_duplication | 187,758 |
| tandem_repeat_or_homopolymer | 160,761 |
| other_difficult | 57,793 |
| low_mappability | 30,462 |

GIAB regions loaded (chr22):

| Stratification | Intervals | Bases |
|---|---|---|
| all_difficult | 55,175 | 13,157,868 |
| low_mappability | 11,654 | 7,148,877 |
| segdup | 205 | 5,997,248 |
| tandem_repeat_homopolymer | 57,258 | 5,653,447 |

## Flagged samples

Flags use z-scores within each sample's population; superpopulation flags are shown for comparison.

| Within population | Within superpopulation | Both | Superpopulation only | Population only |
|---|---|---|---|---|
| 15 | 27 | 13 | 14 | 2 |

Flagged within population, by population:

| Superpop. | Population | Samples | Ti/Tv | Het/hom | Non-ref sites | Mean het/hom z | Not in unrelated set |
|---|---|---|---|---|---|---|---|
| SAS | PJL | 3 | 0 | 3 | 2 | -4.7 | 1 |
| AFR | GWD | 2 | 0 | 1 | 1 | -4.7 | 1 |
| SAS | BEB | 2 | 0 | 2 | 1 | -5.2 | 0 |
| AMR | PUR | 2 | 0 | 1 | 1 | -1.4 | 0 |
| SAS | STU | 2 | 0 | 2 | 1 | -4.6 | 0 |
| EAS | CHS | 1 | 0 | 1 | 1 | -4.7 | 0 |
| AFR | ESN | 1 | 0 | 1 | 1 | -6.9 | 0 |
| EAS | KHV | 1 | 0 | 1 | 1 | -6.9 | 1 |
| EAS | CDX | 1 | 0 | 0 | 1 | -4 | 0 |

## ClinVar pathogenic calls common in a population

| Variant | rsID | Genes | Significance | Review status | Population | AF |
|---|---|---|---|---|---|---|
| chr22:41795840:G:T | rs75338000 | MEI1 | Likely_pathogenic | criteria_provided,_multiple_submitters,_no_conflicts | AFR | 0.0106 |
| chr22:43537404:CCT:C |  | EFCAB6/EFCAB6-AS1 | Pathogenic | criteria_provided,_single_submitter | EAS | 0.0159 |

## Quarantined 1000 Genomes records

| Record | Chrom | Pos | Ref | Alt | Source ID | Reason |
|---|---|---|---|---|---|---|

## Tables

| Table | Type | Rows | GB |
|---|---|---:|---:|
| dim_sample | TABLE | 3,202 | 0.0 |
| dim_population | TABLE | 26 | 0.0 |
| dim_variant | TABLE | 1,066,557 | 0.114 |
| fct_genotype | TABLE | 207,523,964 | 6.433 |
| stg_gnomad | TABLE | 10,882,958 | 1.977 |
| variant_population_freq | TABLE | 6,399,342 | 0.967 |
| qc_allele_count_reconciliation | TABLE | 6,399,342 | 0.654 |
| qc_hardy_weinberg | TABLE | 5,325,475 | 0.572 |
| qc_sample | TABLE | 3,202 | 0.0 |
| gnomad_concordance | TABLE | 5,325,475 | 0.491 |
| clinvar_in_cohort | TABLE | 10,914 | 0.003 |
| variant_context | TABLE | 1,066,557 | 0.033 |
| findings_by_region_class | TABLE | 15 | 0.0 |
| qc_summary | TABLE | 16 | 0.0 |
