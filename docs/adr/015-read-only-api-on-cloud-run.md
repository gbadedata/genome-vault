# ADR-015: A read-only FastAPI service on Cloud Run, with hard cost guards

**Status:** Accepted (November 2026). Replaces the Django design in [ADR-003](003-django-over-flask.md).

## Context

The warehouse answers analytical questions in SQL. People also want quick lookups: one variant, a region, a gene, a sample, the QC summary. The service would query BigQuery on the owner's billing, so an open endpoint must not be able to run up cost.

## Decision

- **FastAPI**, read-only, with no ORM. Each endpoint runs one parameterised SQL statement (`src/genome_vault/api/queries.py`), and values never reach the SQL text.
- **A serving table.** dbt builds `api_variant`: one row per variant with genes, GIAB region class, frequencies per superpopulation, gnomAD comparison, HWE p-values and ClinVar. It is clustered by `chrom, pos` on BigQuery. Every variant query filters on chrom and position (a variant ID's position is parsed first), so BigQuery reads a few blocks, not the table.
  - `api_gene` gives each gene's first overlapping variant position, built from the new `bridge_variant_gene` table. A gene query is then a position range too, and exact for long deletions that start before the gene.
- **One codebase, two backends**, as in the warehouse ([ADR-010](010-dbt-on-duckdb-and-bigquery.md)). DuckDB runs locally and in CI, on the slice warehouse dbt has just built. BigQuery runs on Cloud Run. The API tests compare responses with the warehouse tables queried directly.
- **Least privilege.** The `gv-api` service account has `bigquery.dataViewer` on the `gv` dataset only, plus `bigquery.jobUser` on the project. It has no access to `gv_raw` or the bucket.
- **Cost guards**, layered:
  - every query has `maximum_bytes_billed` = 200 MB;
  - a daily budget of 25 GB: 31 days of it fit inside BigQuery's free 1 TB a month, after which the API returns 503 until midnight UTC;
  - a per-IP token bucket of 60 requests a minute, keyed on the address Google's front end appends, which a client cannot forge;
  - an in-process result cache;
  - Cloud Run `max_instance_count = 1`, so one process holds the limiter, cache and budget;
  - the project's £30 budget alert.
- **Public by default** (`api_public = true`, `allUsers` invoker). The guards above bound the worst case. Set the variable to false to require IAM authentication.

## Alternatives considered

- **Django + DRF.** It brings an ORM and admin built for transactional data this service does not have.
- **Querying the analysis tables directly.** Each lookup would join five or more tables. BigQuery bills at least 10 MB per table read, so a lookup would cost five times more and run slower.
- **Authenticated only.** Safer, but a portfolio API nobody can call is hard to evaluate. With the byte caps in place, an open endpoint's worst case is bounded and small.

## Consequences

- The serving table must be rebuilt (`dbt build`) before a deployment sees new data. The cache lasts for the life of the process, which is right for data that changes only on a build.
- The rate limit and daily budget reset when Cloud Run replaces the instance. The per-query cap and the billing alert still apply.
- While building this, the warehouse found it had been computing ratios in 4-byte floats on DuckDB (`dbt.type_float()`) and 8-byte on BigQuery. Both now use double precision (`float_type()` in `macros/portable.sql`).
