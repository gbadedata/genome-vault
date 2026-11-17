# ADR-010: One dbt project, DuckDB in CI and BigQuery in production

**Status:** Accepted (November 2026)

## Context

The transformations must be tested on every push without cloud credentials or cost, and run unchanged on BigQuery against 207 million genotype rows and the public gnomAD table.

## Decision

A single dbt project in `warehouse/` has two targets:
- `local` (DuckDB) reads the loader's Parquet directly through source `external_location`.
- `bigquery` reads `gv_raw`.

The SQL is written in the intersection of the two dialects. The few differences live in `macros/portable.sql` (integer series, unnesting, genomic windows) or in an adapter branch (`stg_gnomad` reads the public table on BigQuery and a committed extract on DuckDB).

CI runs three jobs:
1. Load the real slice and run `dbt build` on DuckDB, with every model and test.
2. `dbt compile --target bigquery` with an offline profile, then parse every compiled file with sqlglot's BigQuery dialect.
3. `terraform fmt` and `validate`.

## Consequences

- A BigQuery-only syntax error is caught in CI, not in the first cloud run. The first full BigQuery build passed 44 of 44 models and tests.
- Some idioms are written longhand. Interval joins use explicit window keys instead of DuckDB's range join, and `QUALIFY` gets a `where true`.
- Results agree across engines by construction, not by luck: the same invariants run on both.
