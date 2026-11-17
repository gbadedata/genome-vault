# BigQuery build on full chromosome 22 (2026-11-17T20:08:33+00:00)

Project `genome-vault-202605`, dataset `gv`, location US.

## Load

Run `20261117T195041Z` from `gs://genome-vault-202605-gv-data/runs/20261117T195041Z/parquet`.

| Table | Parquet rows | BigQuery rows |
|---|---:|---:|
| clinvar_quarantine | 52 | 52 |
| clinvar_variants | 99,961 | 99,961 |
| ensembl_genes | 1,747 | 1,747 |
| kgp_genotypes | 207,523,893 | 207,523,893 |
| kgp_quarantine | 2 | 2 |
| kgp_samples | 3,202 | 3,202 |
| kgp_samples_vcf | 3,202 | 3,202 |
| kgp_variants | 1,066,555 | 1,066,555 |
| load_runs | 4 | 4 |

## dbt build

Statuses: {'success': 22, 'pass': 22}, 64.8 s, dbt 1.13.0b1.


## QC summary

| Kind | Check | Passed | Detail |
|---|---|---|---|
| finding | ClinVar pathogenic calls common in a population | None | 2 |
| finding | variant-population pairs found in gnomAD | None | 4892150 of 5325475 |
| finding | frequency differences flagged against gnomAD | None | 1718 |
| finding | samples flagged by QC z-scores | None | 27 |
| finding | HWE departures (exact p < threshold, unrelated) | None | 11345 |
| invariant | gnomAD positions are 0-based (+1 matches best) | True | 190739 vs 7609 |
| invariant | allele counts reproduce source (unrelated) | True | 5332775 |
| invariant | genotype rows equal loader count | True | 207523893 |
| invariant | exact HWE test reproduces source HWE p-values | True | 5325475 |
| invariant | every 1000G record loaded or quarantined | True | 1066557 |
| invariant | REF alleles match GRCh38 | True | 1066555 |
| invariant | allele counts reproduce source (all samples) | True | 6399330 |
| invariant | variant rows equal records loaded | True | 1066555 |

## Cost

44 queries; 26.084 GB processed, 26.229 GB billed; largest single query 5.188 GB (cap 20 GB).

## Tables

| Table | Type | Rows | GB |
|---|---|---:|---:|
| dim_sample | TABLE | 3,202 | 0.0 |
| dim_population | TABLE | 26 | 0.0 |
| dim_variant | TABLE | 1,066,555 | 0.114 |
| fct_genotype | TABLE | 207,523,893 | 6.433 |
| stg_gnomad | TABLE | 10,882,958 | 1.977 |
| variant_population_freq | TABLE | 6,399,330 | 0.966 |
| qc_allele_count_reconciliation | TABLE | 6,399,330 | 0.654 |
| qc_hardy_weinberg | TABLE | 5,325,475 | 0.572 |
| qc_sample | TABLE | 3,202 | 0.0 |
| gnomad_concordance | TABLE | 5,325,475 | 0.491 |
| clinvar_in_cohort | TABLE | 10,914 | 0.003 |
| qc_summary | TABLE | 13 | 0.0 |
