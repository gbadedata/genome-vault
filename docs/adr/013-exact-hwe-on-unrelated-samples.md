# ADR-013: Exact Hardy-Weinberg test, on the 2,504 unrelated samples

**Status:** Accepted (November 2026)

## Context

The first version used a chi-square test (1 degree of freedom). On the development slice it flagged **220** departures where the source's own HWE p-values flagged 37.

Almost all of the disagreement came from rare variants, where chi-square is invalid. Take one homozygous carrier and no heterozygotes among 661 people:
- chi-square gives 661, which is p ≈ 1e-145;
- the exact probability is 1/1321 ≈ 0.0008.

Separately, the 1000 Genomes cohort includes 602 trios. Relatives are not independent draws, which the test assumes.

## Decision

- Implement the exact test of Wigginton, Cutler and Abecasis (2005) in portable SQL. It enumerates every possible het count with a `ln(k!)` lookup table, because BigQuery has no `lgamma()`.
- Compute it twice per variant and superpopulation: on **all samples**, to validate against the source, and on the **2,504 phase 3 unrelated samples**, which is the result acted on.
- Define "unrelated" as the phase 3 panel (`integrated_call_samples_v3.20130502.ALL.panel`), not "has no parents in the pedigree". Pedigree founders give 2,590 samples; only the phase 3 list reproduces the source's `*_unrel` allele counts exactly.

## Consequences

- The all-samples p-values reproduce the source's `HWE_<POP>` values in **5,325,475 of 5,325,475** variant-population pairs. The largest difference is 5e-7, the rounding of the VCF's 6-digit floats. That also shows the source computed HWE including relatives.
- On unrelated samples, the full chromosome has 11,345 departing variant-population pairs at p < 1e-6.
- The enumeration costs about 700 MB scanned on BigQuery for all of chr22. That is acceptable.
