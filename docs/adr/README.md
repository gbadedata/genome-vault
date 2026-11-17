# Architecture Decision Records

Each ADR records one decision: the context, what was chosen, what was rejected and why, and the consequences. Superseded ADRs are kept, with a note pointing to what replaced them, so the history of the design stays readable.

| ID | Title | Status |
|---|---|---|
| [ADR-001](001-bigquery-over-cloud-sql.md) | BigQuery over Cloud SQL for the warehouse | Accepted |
| [ADR-002](002-dataflow-over-cloud-functions.md) | Dataflow over Cloud Functions for ingestion | Superseded by ADR-007 |
| [ADR-003](003-django-over-flask.md) | Django + DRF over Flask for the API | Superseded |
| [ADR-004](004-star-schema-design.md) | Star schema with separate sample and variant dimensions | Superseded by ADR-008 |
| [ADR-005](005-pysam-for-vcf-parsing.md) | pysam over Hail for VCF parsing | Superseded by ADR-009 |
| [ADR-006](006-looker-studio-for-bi.md) | Looker Studio over Metabase or Superset for BI | Deferred |
| [ADR-007](007-python-loader-and-bq-load.md) | A Python loader writing Parquet, loaded with `bq load` | Accepted |
| [ADR-008](008-sparse-genotype-fact.md) | Sparse genotype fact table | Accepted |
| [ADR-009](009-cyvcf2-for-genotypes.md) | cyvcf2 for genotype parsing | Accepted |
| [ADR-010](010-dbt-on-duckdb-and-bigquery.md) | One dbt project, DuckDB in CI and BigQuery in production | Accepted |
| [ADR-011](011-us-location-and-cost-guards.md) | US location for every dataset, and hard cost guards | Accepted |
| [ADR-012](012-real-data-only.md) | Real public data only, with a development slice cut from it | Accepted |
| [ADR-013](013-exact-hwe-on-unrelated-samples.md) | Exact Hardy-Weinberg test, on the 2,504 unrelated samples | Accepted |
| [ADR-014](014-structural-variant-identity.md) | Structural-variant identity includes END and SVLEN | Accepted |
