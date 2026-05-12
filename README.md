<div align="center">

# genome-vault

**Genomic variant warehouse on Google Cloud — BigQuery, Dataflow, Django, Looker Studio.**

[![CI](https://github.com/gbadedata/genome-vault/actions/workflows/ci.yml/badge.svg)](https://github.com/gbadedata/genome-vault/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.12](https://img.shields.io/badge/python-3.12-blue.svg)](https://www.python.org/downloads/release/python-3120/)

[Architecture](#architecture) · [Quickstart](#quickstart) · [Data model](#data-model)

</div>

---

## What this is

genome-vault is a data platform for querying genomic variants at scale. It ingests raw VCF (Variant Call Format) data from public genomic datasets, validates and conforms it against a star-schema warehouse, joins per-sample observations against population frequency references, and exposes the results through both a REST API (for programmatic access) and a Looker Studio dashboard (for exploration).

The platform is built around real bioinformatics data and standards:

- **1000 Genomes Project** — 2,500 samples across 26 populations, used as the per-sample dimension
- **gnomAD** (Genome Aggregation Database) — 800K+ samples, used as the population frequency reference
- **VCF 4.2/4.3** — the file format the variant data is encoded in
- **HGVS** — the standard nomenclature for describing sequence variants
- **dbSNP rsIDs** — the canonical identifier for known variants
- **GRCh38** — the human reference genome assembly used throughout

## Architecture

```text
                          ┌──────────────────────────────┐
                          │ Public datasets              │
                          │ - 1000 Genomes (BigQuery)    │
                          │ - gnomAD (BigQuery)          │
                          └───────────────┬──────────────┘
                                          │
                                          ▼
┌────────────┐         ┌──────────────┐         ┌──────────────────┐
│ Dataflow   │────────▶│ GCS Bronze   │────────▶│ BigQuery Bronze  │
│ ingestion  │         │ raw VCF      │         │ raw variant rows │
└────────────┘         └──────────────┘         └────────┬─────────┘
                                                         │
                                                         ▼
                                                ┌──────────────────┐
                                                │ BigQuery Silver  │
                                                │ star schema      │
                                                │ - fact_variant_  │
                                                │   call           │
                                                │ - dim_sample     │
                                                │ - dim_variant    │
                                                │ - dim_population │
                                                └────────┬─────────┘
                                                         │
                          ┌──────────────────────────────┴───────┐
                          │                                      │
                          ▼                                      ▼
                  ┌──────────────┐                       ┌──────────────┐
                  │ Django + DRF │                       │ Looker Studio│
                  │ on Cloud Run │                       │ dashboards   │
                  └──────────────┘                       └──────────────┘
```

Data flows in one direction through three quality tiers (medallion architecture):

- **Bronze** — raw VCF rows as ingested, immutable for replay
- **Silver** — validated, conformed to the star schema, joined against population references
- **Gold** — pre-aggregated rollups for dashboards (variant counts per gene, per population, per impact severity)

## Quickstart

You need: Python 3.12, Terraform >= 1.9, gcloud CLI, an active GCP billing account.

```bash
# 1. Clone and enter the project
git clone https://github.com/gbadedata/genome-vault.git
cd genome-vault

# 2. Bootstrap GCP — creates the project, attaches billing, enables APIs,
#    creates the GCS bucket that holds Terraform state.
make bq-bootstrap

# 3. Set up Python and pre-commit hooks
make setup
source .venv/bin/activate

# 4. Provision infrastructure (BigQuery datasets, GCS buckets, IAM)
make tf-init
make tf-plan
make tf-apply

# 5. Run the ingestion pipeline for a small sample
python -m genome_vault.ingestion.run --chromosome=22 --samples=10

# 6. Run the API locally
python -m genome_vault.api.main

# 7. Tear down when finished
make tf-destroy
```

## Data model

The Silver layer is a classical star schema, optimised for the analytical queries genomic researchers actually run.

| Table | Type | Grain |
|---|---|---|
| `fact_variant_call` | Fact | One row per (variant × sample × call) |
| `dim_sample` | Dimension | One row per sample, joined to demographic and population attributes |
| `dim_variant` | Dimension | One row per unique variant, joined to gnomAD frequencies and HGVS annotations |
| `dim_population` | Dimension | One row per population (26 from 1000 Genomes, plus aggregate continental groups) |

Typical questions the schema answers in a single join:

- What variants in BRCA1 have a population allele frequency below 0.01% globally but above 1% in Finnish samples?
- Which loss-of-function variants in any gene have at least one homozygous carrier in 1000 Genomes?
- How does the rate of pathogenic missense variants in CYP2D6 differ between African and European populations?

## Project structure

```text
genome-vault/
├── src/genome_vault/
│   ├── ingestion/        # VCF parsing, Dataflow pipelines
│   ├── warehouse/        # BigQuery schema management, DDL, materialised views
│   ├── api/              # Django + DRF REST API
│   ├── observability/    # Structured logging, metrics
│   └── domain/           # Pure domain models (Variant, Sample, Population)
├── tests/
│   ├── unit/             # No I/O, no network
│   ├── integration/      # Requires GCP credentials
│   └── fixtures/         # Sample VCF files and expected outputs
├── infra/terraform/
│   ├── modules/          # Reusable modules (bigquery_dataset, gcs_bucket)
│   └── environments/dev/ # Dev environment composition
├── docs/
│   ├── adr/              # Architecture Decision Records
│   ├── architecture/     # Diagrams
│   └── runbooks/         # Operational guides
└── scripts/              # bootstrap-gcp.sh, helper scripts
```

## Architecture decision records

Each ADR documents one architectural decision, the alternatives considered, and the reasoning. Read them when you want to understand *why* the platform looks the way it does.

| ID | Title |
|---|---|
| [ADR-001](docs/adr/001-bigquery-over-cloud-sql.md) | BigQuery over Cloud SQL for the warehouse |
| [ADR-002](docs/adr/002-dataflow-over-cloud-functions.md) | Dataflow over Cloud Functions for ingestion |
| [ADR-003](docs/adr/003-django-over-flask.md) | Django + DRF over Flask for the API |
| [ADR-004](docs/adr/004-star-schema-design.md) | Star schema with separate sample and variant dimensions |
| [ADR-005](docs/adr/005-pysam-for-vcf-parsing.md) | pysam over Hail for VCF parsing in this project |
| [ADR-006](docs/adr/006-looker-studio-for-bi.md) | Looker Studio over Metabase or Superset for BI |

## Why I built this

Genomic data is a uniquely demanding domain for a data platform. A single human VCF file contains millions of variant calls; gnomAD's reference is hundreds of millions of variants across half a million people. Querying this efficiently means thinking carefully about partitioning, clustering, and the cost of every column scanned — the kind of disciplined warehouse design that's easy to skip in projects with smaller data.

The other reason is that bioinformatics workflows are often built as scattered Python scripts feeding into ad-hoc Jupyter notebooks. A proper warehouse — with versioned schemas, a star-schema model, a queryable API, and a dashboard — turns one-off analysis into a platform other people can build on. That transition is what this project demonstrates.

## Author

**Gbade Odimayo** — [@gbadedata](https://github.com/gbadedata)

Issues, questions, or improvements: [open an issue](https://github.com/gbadedata/genome-vault/issues) or send a pull request.

## License

MIT — see [LICENSE](LICENSE).
