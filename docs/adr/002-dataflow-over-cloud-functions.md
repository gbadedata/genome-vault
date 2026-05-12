# ADR-002: Dataflow over Cloud Functions for ingestion

**Status:** Accepted

## Context

genome-vault ingests VCF (Variant Call Format) files containing millions of variant rows. The ingestion pipeline must parse VCF, validate each record, enrich it with reference data, and write the result to BigQuery in batches.

This work could be implemented as:

- Cloud Functions triggered by GCS file uploads
- Dataflow (managed Apache Beam) jobs
- Cloud Run jobs
- Cloud Composer (managed Airflow) DAGs orchestrating any of the above

## Decision

Use **Google Cloud Dataflow** (managed Apache Beam) as the ingestion engine, with pipelines written in the Python Beam SDK.

## Alternatives considered

**Cloud Functions**

- Simplest deployment, lowest setup overhead
- Hard 9-minute execution limit on 2nd-gen functions, which is too short for parsing a multi-GB VCF file
- No native parallelism across rows of a single input — one function instance per file, scaling stops at the file boundary
- Not the right primitive when the unit of work is "every row in a large file"

**Cloud Run jobs**

- More flexible than Cloud Functions, can run for hours, easy to package as a container
- Manual parallelism — you have to split the input yourself and orchestrate per-shard jobs
- Loses Beam's automatic re-keying, windowing, and exactly-once semantics
- A reasonable fallback for simple workloads, but underspecified for this one

**Cloud Composer (Airflow)**

- Orchestration layer rather than a processing engine — you'd still need Dataflow or Cloud Run inside the DAG
- Adds another moving part for no benefit at this scale
- Worth adopting if/when the platform has many interdependent pipelines on a schedule

**Self-hosted Spark on Dataproc**

- Powerful, well-understood, lots of bioinformatics libraries (Hail, GLOW) target Spark
- Operationally heavier than Dataflow — cluster lifecycle management, version pinning, autoscaling configuration
- Worth using if/when we adopt Hail for serious downstream genomics; for ingestion specifically, Dataflow's serverless model wins

## Consequences

**Positive**

- Native parallelism — Beam splits the input automatically and scales workers based on backlog
- Exactly-once write semantics into BigQuery via the streaming insert API or the file-load batch API
- Same pipeline code can run locally (DirectRunner) for testing and on Dataflow (DataflowRunner) for production, with one CLI flag
- First-class GCP integration — auth via service account, logs to Cloud Logging, metrics to Cloud Monitoring

**Negative**

- Beam's programming model has a learning curve — `PCollection`, `PTransform`, side inputs, windowing are unfamiliar to engineers who haven't used it
- Per-worker billing means small or test workloads have higher minimum cost than Cloud Functions would
- Cold start: a Dataflow job takes 2-5 minutes to provision workers before it starts doing work, which makes it unsuitable for sub-minute-latency requirements

## Future revisit triggers

This decision is worth re-examining if any of these become true:

- A real-time use case emerges that needs sub-minute end-to-end latency (BigQuery's native streaming inserts may be enough, or we add a Pub/Sub + Dataflow streaming variant)
- The team standardises on Spark/Hail for downstream analytics (consolidating on Dataproc may reduce platform sprawl)
- A simpler use case appears that's genuinely a good fit for Cloud Functions (e.g., per-file metadata extraction at ingest time)
