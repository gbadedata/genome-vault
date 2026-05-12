# ADR-001: BigQuery over Cloud SQL for the warehouse

**Status:** Accepted

## Context

genome-vault stores tens of millions of variant calls and joins them against reference data orders of magnitude larger (gnomAD alone has ~750 million variants). The primary access pattern is analytical: aggregations, filters by genomic region, joins between fact and dimension tables. The system also exposes a REST API that returns small, indexed lookups.

We need a warehouse that handles the analytical load efficiently without requiring us to manage servers, sharding, or query optimisation manually.

## Decision

Use **Google BigQuery** as the warehouse for all variant data, partitioned by chromosome and clustered by variant position.

## Alternatives considered

**Cloud SQL with PostgreSQL**

- Familiar relational model, full SQL support, easy local development with stock Postgres
- Vertical scaling ceiling — a single Cloud SQL instance maxes out at 624 GB RAM and 96 vCPUs, expensive at that size, still slower than BigQuery for analytical scans
- Genomic indexes (variant position lookups across hundreds of millions of rows) require careful index design and maintenance
- Pay for capacity whether you query or not, which is wasteful for a portfolio platform that's sometimes idle

**Cloud Spanner**

- Globally distributed, strongly consistent — overkill for an analytical workload that doesn't need cross-region transactions
- Minimum node cost is significant
- Optimised for OLTP, not the OLAP scans that dominate this platform

**Self-hosted Postgres with the pg_variant extension**

- Maximum flexibility, lowest per-query cost at small scale
- Operationally the heaviest option — backups, patching, replication, failover all become our problem
- Loses the GCP-native integration that makes the rest of the platform cheap to build

## Consequences

**Positive**

- Serverless — zero cost when idle, scales automatically when queried
- Native integration with Dataflow (write directly to BigQuery from a Beam pipeline), with `bigquery-public-data` (gnomAD and 1000 Genomes are pre-loaded), and with Looker Studio
- Partitioning by chromosome + clustering by position turns full-table scans into pinpoint reads — typical region queries scan kilobytes, not gigabytes
- Standard SQL is a first-class citizen, with windowing, structured types, and array functions that genomic queries need

**Negative**

- Per-query billing model means a poorly-written query (e.g., `SELECT *` against a multi-TB table) can be expensive — discipline required on column selection and partition filters
- Joins across very large tables can be slow without proper clustering, which means thinking about access patterns at schema design time
- Cold-start latency on the first query of a session is 1-3 seconds — fine for analytical work, unacceptable for an interactive API, so the API layer materialises hot rollups into a smaller Postgres-on-Cloud-SQL cache for sub-100ms responses (see ADR-003)

## Future revisit triggers

This decision is worth re-examining if any of these become true:

- The platform moves to a fully real-time streaming model where BigQuery's mini-batch streaming inserts become a bottleneck
- A use case emerges that needs strong transactional consistency across many small writes (BigQuery is append-optimised, not OLTP)
- Per-query cost predictability becomes more important than serverless flexibility (e.g., a fixed-budget shared environment)
