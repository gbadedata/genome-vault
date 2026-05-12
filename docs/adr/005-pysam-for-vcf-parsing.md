# ADR-005: pysam over Hail for VCF parsing in this project

**Status:** Accepted

## Context

VCF (Variant Call Format) is the canonical file format for sequencing variant data. Parsing it correctly is non-trivial: the header carries critical schema information, INFO and FORMAT fields are typed and may be missing, multi-allelic sites need special handling, and the file is typically gzipped + bgzipped for random-access seeking.

The Python ecosystem offers several options for VCF parsing.

## Decision

Use **pysam** (a Python wrapper around htslib, the canonical samtools/bcftools backend) for all VCF parsing in the ingestion pipeline.

## Alternatives considered

**Hail**

- Distributed genomic data analysis library built on Apache Spark, developed by the Broad Institute
- First-class for gnomAD, MatrixTable abstraction, very large-scale analytics
- Pulls in Spark, requires JVM, has a significant operational footprint
- Worth adopting for serious downstream analytics; overkill for this project's ingestion stage

**cyvcf2**

- Cython wrapper around htslib (same backend as pysam)
- Genuinely fast, very Pythonic API for variant iteration
- Smaller community than pysam, fewer Stack Overflow answers, less tooling integration
- Reasonable alternative, but pysam wins on ecosystem familiarity

**Pure Python (no htslib)** — e.g., `vcf` or `PyVCF3`

- No native dependency, easy to install
- Significantly slower (5-20x) than htslib-backed options
- Less robust handling of edge cases (multi-allelic sites, complex INFO types)
- Acceptable for small files or quick scripts; not for a production-grade ingestion pipeline

**bcftools** invoked as a subprocess

- The reference implementation, used by virtually every bioinformatics pipeline
- Forces shelling out and parsing stdout, which is awkward inside a Beam pipeline
- Useful for command-line verification of files; not the right primitive inside our code

## Consequences

**Positive**

- Battle-tested htslib backend handles every VCF edge case correctly: multi-allelic decomposition, structural variants, phased vs unphased calls, missing values, INFO/FORMAT type coercion
- Streaming iterator API — one record at a time, no memory blowup on large files
- Used by the broader bioinformatics community, so debugging and asking for help is easier
- Native bgzip seek support — we can read a specific genomic region without parsing the whole file

**Negative**

- C extension means it doesn't pip-install on every platform without build tools; we mitigate this by pinning a Linux-only wheel in the requirements
- No built-in distributed processing — we rely on Beam to handle that layer
- Single-threaded per process — Beam fans out work across workers, so this isn't a practical limit

## Future revisit triggers

This decision is worth re-examining if any of these become true:

- The project adopts Hail for downstream analytics, in which case using Hail's `import_vcf` for ingestion too may unify the stack
- Per-row parsing latency becomes the bottleneck (cyvcf2 is measurably faster in tight loops; benchmark before switching)
- We need to parse a format pysam doesn't support well (BCF v3, structural variant formats)
