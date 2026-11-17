# ADR-014: Structural-variant identity includes END and SVLEN

**Status:** Accepted (November 2026)

## Context

Variants were keyed as `chrom:pos:ref:alt`. That is a complete identity for sequence-resolved alleles, but not for symbolic structural-variant alleles. `<DEL>` says a deletion starts after `pos`, not where it stops, so two deletions of different lengths at the same base share the key.

On full chr22, two records were quarantined as `DUPLICATE_VARIANT`: a `<DEL>` at 22,857,056 and an `<INS>` at 49,951,209. Each shared its key with an earlier record.

## Decision

For symbolic alleles only, the key is `chrom:pos:ref:alt:end:svlen`, taken from the record's `END` and `SVLEN`. SVLEN is included because for insertions END is close to POS whatever the inserted length: on the development slice, a 300 bp insertion has END 25 bp after POS. Sequence-resolved alleles keep `chrom:pos:ref:alt`, so SNV and indel keys, and every join on them, are unchanged.

## Consequences

- Records that still collide after this change are true duplicates (same type, start, end and length), and stay quarantined.
- The 1,460 structural-variant keys on chr22 change format. `variant_key` (the record number) is unchanged, so no fact rows move.
- A unit test checks the format on the 9 real structural variants in the slice.
