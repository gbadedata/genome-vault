# Architecture Decision Records

This directory holds the architectural decisions that shape genome-vault. Each ADR captures one decision, the alternatives considered, and the reasoning, so future contributors can understand *why* the platform looks the way it does — not just *what* it is.

## Format

Each ADR follows a lightweight template:

- **Status** — Proposed, Accepted, Superseded
- **Context** — what problem we're solving
- **Decision** — what we chose
- **Alternatives** — what we rejected and why
- **Consequences** — tradeoffs we accept

## Index

| ID | Title | Status |
|---|---|---|
| [ADR-001](001-bigquery-over-cloud-sql.md) | BigQuery over Cloud SQL for the warehouse | Accepted |
| [ADR-002](002-dataflow-over-cloud-functions.md) | Dataflow over Cloud Functions for ingestion | Accepted |
| [ADR-003](003-django-over-flask.md) | Django + DRF over Flask for the API | Accepted |
| [ADR-004](004-star-schema-design.md) | Star schema with separate sample and variant dimensions | Accepted |
| [ADR-005](005-pysam-for-vcf-parsing.md) | pysam over Hail for VCF parsing in this project | Accepted |
| [ADR-006](006-looker-studio-for-bi.md) | Looker Studio over Metabase or Superset for BI | Accepted |
