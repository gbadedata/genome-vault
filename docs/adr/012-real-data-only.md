# ADR-012: Real public data only, with a development slice cut from it

**Status:** Accepted (November 2026)

## Context

Synthetic genotypes would let tests pass while hiding the quirks real data has. Examples found in this build:
- structural variants that start at the same base and differ only in END and SVLEN;
- symbolic SV alleles with lowercase text;
- ClinVar records with no ALT;
- a 0-based coordinate column in gnomAD;
- a mis-declared INFO field.

## Decision

Every input is a real, open dataset, downloaded by `scripts/fetch_sources.py` with resume, a size check and a SHA-256 recorded in `data/sources/manifest.json`.

For tests and CI, the same script cuts **chr22:42,050,000-42,250,000** (the CYP2D6 region, chosen because paralogs and structural variation make it hard) from each source into `tests/fixtures/real/`:
- 5,452 variants × 3,202 samples;
- 2,388 ClinVar records;
- 20 genes;
- 56,927 gnomAD rows;
- the GIAB region slices;
- 200 kb of reference sequence.

## Consequences

- Test expectations are facts about the sources, not numbers chosen to make the code pass. For example, "23 ClinVar records in the slice have no ALT" and "allele counts equal the source's AC/AN".
- The fixtures are a few MB in git. That is accepted as the cost of realism.
- Unit tests contain one hand-written five-line BED, used only to pin down the interval-merge edge cases (touching and overlapping intervals). It is not a dataset.
