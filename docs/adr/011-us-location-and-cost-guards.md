# ADR-011: US location for every dataset, and hard cost guards

**Status:** Accepted (November 2026)

## Context

The gnomAD v3 frequencies are read from `bigquery-public-data.gnomAD.v3_genomes__chr22`, which is in the US multi-region. BigQuery cannot join tables in different locations. The original design put the datasets in EU.

## Decision

- The bucket and the `gv_raw` and `gv` datasets are in **US**. Terraform's `bq_location` variable refuses any other value.
- The dbt BigQuery profile sets `maximum_bytes_billed: 20000000000`, so any single query that would scan more than 20 GB fails before it runs. The whole public gnomAD chr22 table is 19.1 GB, so no gnomAD query can exceed the cap.
- Every script names its project explicitly through `GV_PROJECT_ID` (default `genome-vault-202605`).
- A billing budget alerts at 50%, 90% and 100% of £30 a month.

## Consequences

- The data lives outside the UK and EU. That is acceptable for open, consented reference data like this; it would need revisiting for clinical data.
- Measured cost of a full build: 26.2 GB billed over 44 queries, with the largest single query at 5.2 GB.
- Why `GV_PROJECT_ID` rather than `GCP_PROJECT_ID`: a stale `GCP_PROJECT_ID` from another project in the same shell once pointed the scripts at the wrong project. A name only this repository uses removes that risk.
