# ADR-007: A Python loader writing Parquet, loaded with `bq load`

**Status:** Accepted (November 2026). Supersedes [ADR-002](002-dataflow-over-cloud-functions.md).

## Context

The input is one chromosome of the 1000 Genomes 30x panel: a 446 MB bgzipped VCF with 1,066,557 records × 3,202 samples. Every record must end up loaded or quarantined with a reason, and the load must be repeatable and cheap.

## Decision

`genome-vault load` (Python, cyvcf2) streams the VCF once and writes Parquet:
- one directory per table;
- chunked at 2 million rows, so memory stays flat;
- an explicit Arrow schema per table.

`scripts/load_bigquery.sh` uploads that Parquet to `gs://<project>-gv-data/runs/<run_id>/` and runs `bq load --replace` per table into `gv_raw`. It then checks BigQuery's row counts against the Parquet.

## Alternatives considered

- **Dataflow / Apache Beam.** Built for data far bigger than one chromosome. It brings cluster start-up time, worker cost and a second programming model, and nothing here needs them. Full chr22 loads in **342 seconds** on a laptop.
- **Streaming inserts or the Storage Write API.** These are billed per row and give no file to re-check. Parquet plus a load job is free to load and leaves an auditable artefact per run.
- **Variant Transforms (Google's Dataflow-based VCF loader).** It has the same overhead as Dataflow, and it hides the quarantine rules this project wants to own and test.

## Consequences

- The same Parquet feeds DuckDB in CI and BigQuery in production, so the loader is tested once and used twice.
- Scaling to the whole genome would mean running one loader per chromosome in parallel (Cloud Run jobs or Batch). It would not need a rewrite.
- Each run's Parquet stays in GCS for 90 days (bucket lifecycle rule) for provenance.
