# ADR-009: cyvcf2 for genotype parsing

**Status:** Accepted (November 2026). Supersedes [ADR-005](005-pysam-for-vcf-parsing.md).

## Context

The loader reads 3,202 genotypes per record across 1,066,557 records. Parsing them one Python object at a time would dominate the run time.

## Decision

Use **cyvcf2**, whose `gt_types` (with `gts012=True`) returns each record's genotypes as one numpy array: 0 hom-ref, 1 het, 2 hom-alt, 3 unknown. Non-reference calls are selected with a vectorised mask and appended to the Parquet writer as arrays.

pysam stays as a dependency, but only for `scripts/fetch_sources.py`, which cuts and tabix-indexes the development slice.

## Consequences

- Full chr22 (207.5 million genotype rows written) loads in 342 seconds.
- cyvcf2 wraps htslib, so it is fussy about headers. The panel declares `AC` with the wrong `Number=`, and htslib warns about it. The loader reads AC and AN as written and reconciles them against its own counts.
