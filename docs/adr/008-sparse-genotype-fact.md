# ADR-008: Sparse genotype fact table

**Status:** Accepted (November 2026). Supersedes [ADR-004](004-star-schema-design.md).

## Context

A dense genotype matrix for chr22 has 1,066,557 variants × 3,202 samples = **3.42 billion** cells. Almost all of them are homozygous-reference, which carries no information beyond "this sample was called".

## Decision

`fct_genotype` stores only non-reference calls: 1 for heterozygous, 2 for homozygous alternate, and -1 for missing. Homozygous-reference is implied. Allele numbers come from sample counts, not from rows. On chr22 that is **207,523,964 rows (6.1% of the dense matrix)**, 6.4 GB in BigQuery, clustered by `variant_key`.

The rest of the star:
- `dim_sample`: pedigree, population, superpopulation and the phase 3 unrelated flag.
- `dim_variant`: alleles, class, REF check against GRCh38, overlapping Ensembl genes and ClinVar.
- `dim_population` and `variant_context`: GIAB difficult-region class.

## Alternatives considered

- **Dense rows.** About 16 times more storage and scan cost for no extra information.
- **Genotype arrays per variant** (`ARRAY<INT64>` of 3,202). Compact, but BigQuery has to unnest them for every per-sample question, and DuckDB and BigQuery handle arrays differently.

## Consequences

- Every allele count must add back the implied hom-ref calls. A dbt invariant checks this: recomputed AC and AN equal the source's own in all 6,399,342 variant-population comparisons. This is what makes the sparse model safe.
- Any query for a sample's genotype at a variant must treat "no row" as hom-ref. That stays true because missing calls are stored as rows (`gt = -1`), not dropped. The loader counts them; the phased panel has none on chr22.
