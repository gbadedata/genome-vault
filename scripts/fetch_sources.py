#!/usr/bin/env python3
"""Download the real public sources genome-vault is built on, and cut a small
development slice from them.

Run on a machine with normal internet access (it needs EBI, NCBI, Ensembl and
UCSC):

    pip install pysam requests
    python scripts/fetch_sources.py                 # download + dev slice
    python scripts/fetch_sources.py --gnomad-schema # also save the gnomAD
                                                    # BigQuery schema (needs bq)

Sources (all open data, no access restrictions):

* 1000 Genomes 30x on GRCh38 (NYGC), phased SNV/INDEL/SV panel, chr22,
  3,202 samples, plus the sample pedigree/population table.
* ClinVar GRCh38 VCF (NCBI), sliced to chromosome 22.
* Ensembl GRCh38 gene annotation (GFF3) for chromosome 22.
* UCSC hg38 chr22 reference sequence, for checking REF alleles.

Large files are downloaded once, resumed if interrupted, and checked against
the server's Content-Length. Every file gets a SHA-256 in
data/sources/manifest.json together with its URL and retrieval time, so each
number the warehouse reports can be traced to an exact input.

The development slice (default: chr22:42,050,000-42,250,000, around CYP2D6)
is written to tests/fixtures/real/ and is small enough to commit.
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urljoin

import requests

EBI = "https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/"
KGP_PANEL_DIR = EBI + "working/20220422_3202_phased_SNV_INDEL_SV/"
KGP_SAMPLES = EBI + "20130606_g1k_3202_samples_ped_population.txt"
CLINVAR = "https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz"
ENSEMBL_GFF3_DIR = "https://ftp.ensembl.org/pub/current_gff3/homo_sapiens/"
UCSC_CHR22 = "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr22.fa.gz"

GNOMAD_TABLE = "bigquery-public-data:gnomAD.v3_genomes__chr22"

ROOT = Path(__file__).resolve().parents[1]
FULL = ROOT / "data" / "full"
SOURCES = ROOT / "data" / "sources"
FIXTURES = ROOT / "tests" / "fixtures" / "real"

SESSION = requests.Session()
SESSION.headers["User-Agent"] = "genome-vault/0.2 (+https://github.com/gbadedata/genome-vault)"


def log(msg: str) -> None:
    print(msg, flush=True)


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def list_dir(url: str) -> list[str]:
    """File names linked from an Apache/nginx directory listing."""
    r = SESSION.get(url, timeout=60)
    r.raise_for_status()
    names = re.findall(r'href="([^"?/][^"]*)"', r.text)
    return sorted({n for n in names if not n.startswith(("http", "/", "#"))})


def pick(names: list[str], pattern: str, what: str) -> str:
    hits = [n for n in names if re.search(pattern, n)]
    if len(hits) != 1:
        raise SystemExit(f"Expected exactly one {what} matching {pattern!r}, found {hits}")
    return hits[0]


def download(url: str, dest: Path, retries: int = 5) -> dict:
    """Download with resume. Verifies the final size against Content-Length."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    head = SESSION.head(url, timeout=60, allow_redirects=True)
    head.raise_for_status()
    expected = int(head.headers.get("Content-Length", 0)) or None

    if dest.exists() and (expected is None or dest.stat().st_size == expected):
        log(f"  already have {dest.name} ({dest.stat().st_size:,} bytes)")
        retrieved = dt.datetime.fromtimestamp(dest.stat().st_mtime, dt.UTC).replace(microsecond=0).isoformat()
    else:
        retrieved = None
        for attempt in range(1, retries + 1):
            have = part.stat().st_size if part.exists() else 0
            headers = {"Range": f"bytes={have}-"} if have else {}
            try:
                with SESSION.get(url, headers=headers, stream=True, timeout=120) as r:
                    if have and r.status_code != 206:  # server ignored Range: restart
                        have = 0
                        part.unlink(missing_ok=True)
                    r.raise_for_status()
                    mode = "ab" if have else "wb"
                    done, last = have, time.monotonic()
                    with part.open(mode) as f:
                        for chunk in r.iter_content(1 << 20):
                            f.write(chunk)
                            done += len(chunk)
                            if time.monotonic() - last > 10:
                                pct = f" ({done / expected:.0%})" if expected else ""
                                log(f"    {dest.name}: {done / 1e6:,.0f} MB{pct}")
                                last = time.monotonic()
                if expected and part.stat().st_size != expected:
                    raise OSError(f"size {part.stat().st_size} != Content-Length {expected}")
                part.replace(dest)
                break
            except (requests.RequestException, OSError) as exc:
                log(f"    attempt {attempt} failed: {exc}")
                if attempt == retries:
                    raise
                time.sleep(5 * attempt)
        log(f"  downloaded {dest.name} ({dest.stat().st_size:,} bytes)")
        retrieved = now()

    return {
        "url": url,
        "path": str(dest.relative_to(ROOT)),
        "bytes": dest.stat().st_size,
        "content_length": expected,
        "last_modified": head.headers.get("Last-Modified"),
        "sha256": sha256(dest),
        "retrieved_at": retrieved,
    }


def vcf_header_value(path: Path, key: str) -> str | None:
    with gzip.open(path, "rt") as f:
        for line in f:
            if not line.startswith("##"):
                return None
            if line.startswith(f"##{key}="):
                return line.strip().split("=", 1)[1]
    return None


def slice_vcf(src: Path, dest: Path, contig: str, start: int, end: int) -> int:
    """Write the records of src in contig:start-end (1-based, inclusive) to a
    bgzipped, tabix-indexed VCF. Returns the number of records written."""
    import pysam

    dest.parent.mkdir(parents=True, exist_ok=True)
    plain = dest.with_suffix("")  # .vcf
    n = 0
    with pysam.VariantFile(str(src)) as vin, pysam.VariantFile(str(plain), "w", header=vin.header) as vout:
        for rec in vin.fetch(contig, start - 1, end):
            vout.write(rec)
            n += 1
    pysam.tabix_index(str(plain), preset="vcf", force=True)  # writes dest + .tbi, removes plain
    return n


def count_vcf(path: Path, contig: str | None = None) -> int:
    import pysam

    with pysam.VariantFile(str(path)) as v:
        it = v.fetch(contig) if contig else v.fetch()
        return sum(1 for _ in it)


def slice_gff3(src: Path, dest: Path, seqid: str, start: int | None = None, end: int | None = None) -> int:
    """Keep gene-level features (and the header) on seqid, optionally only those
    overlapping start-end."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with gzip.open(src, "rt") as fin, gzip.open(dest, "wt") as fout:
        for line in fin:
            if line.startswith("##gff-version") or line.startswith("##sequence-region"):
                fout.write(line)
                continue
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) != 9 or cols[0] != seqid or cols[2] not in {"gene", "ncRNA_gene", "pseudogene"}:
                continue
            s, e = int(cols[3]), int(cols[4])
            if start is not None and (e < start or s > end):
                continue
            fout.write(line)
            n += 1
    return n


def slice_fasta(src: Path, dest: Path, start: int, end: int) -> int:
    """Extract chr22:start-end from a single-sequence gzipped FASTA."""
    with gzip.open(src, "rt") as f:
        header = f.readline().strip()
        seq = "".join(line.strip() for line in f)
    sub = seq[start - 1 : end]
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("w") as out:
        out.write(f"{header.split()[0]}:{start}-{end}\n")
        for i in range(0, len(sub), 60):
            out.write(sub[i : i + 60] + "\n")
    return len(sub)


def gnomad_schema() -> dict:
    if not shutil.which("bq"):
        raise SystemExit("bq not found: install the Google Cloud CLI or drop --gnomad-schema")
    SOURCES.mkdir(parents=True, exist_ok=True)
    out = SOURCES / "gnomad_v3_chr22_schema.json"
    table = subprocess.run(
        ["bq", "show", "--format=prettyjson", GNOMAD_TABLE],
        check=True, capture_output=True, text=True,
    ).stdout
    meta = json.loads(table)
    out.write_text(json.dumps(meta.get("schema", {}), indent=2))
    info = {
        "table": GNOMAD_TABLE,
        "location": meta.get("location"),
        "num_rows": meta.get("numRows"),
        "num_bytes": meta.get("numBytes"),
        "last_modified_ms": meta.get("lastModifiedTime"),
        "schema_path": str(out.relative_to(ROOT)),
        "retrieved_at": now(),
    }
    log(f"  gnomAD table: {info['num_rows']} rows, {int(info['num_bytes'] or 0) / 1e9:.1f} GB, location {info['location']}")
    return info


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region-start", type=int, default=42_050_000)
    ap.add_argument("--region-end", type=int, default=42_250_000)
    ap.add_argument("--gnomad-schema", action="store_true", help="also save the gnomAD v3 BigQuery schema (needs bq)")
    args = ap.parse_args()
    start, end = args.region_start, args.region_end
    if not 1 <= start < end:
        raise SystemExit("region start must be >= 1 and below region end")

    manifest: dict = {"created_at": now(), "dev_region": f"chr22:{start}-{end}", "sources": {}, "fixtures": {}}

    log("== Resolving file names")
    panel_files = list_dir(KGP_PANEL_DIR)
    kgp_vcf = pick(panel_files, r"chr22\..*\.vcf\.gz$", "1000 Genomes chr22 VCF")
    kgp_tbi = pick(panel_files, re.escape(kgp_vcf) + r"\.tbi$", "1000 Genomes chr22 index")
    gff_files = list_dir(ENSEMBL_GFF3_DIR)
    gff = pick(gff_files, r"^Homo_sapiens\.GRCh38\.\d+\.chromosome\.22\.gff3\.gz$", "Ensembl chr22 GFF3")
    log(f"  1000 Genomes: {kgp_vcf}")
    log(f"  Ensembl:      {gff}")

    log("== Downloading (resumable; the 1000 Genomes file is the big one)")
    src = manifest["sources"]
    src["kgp_chr22_vcf"] = download(KGP_PANEL_DIR + kgp_vcf, FULL / kgp_vcf)
    src["kgp_chr22_tbi"] = download(KGP_PANEL_DIR + kgp_tbi, FULL / kgp_tbi)
    src["kgp_samples"] = download(KGP_SAMPLES, FULL / Path(KGP_SAMPLES).name)
    src["clinvar_vcf"] = download(CLINVAR, FULL / "clinvar.vcf.gz")
    src["clinvar_tbi"] = download(CLINVAR + ".tbi", FULL / "clinvar.vcf.gz.tbi")
    src["ensembl_gff3"] = download(urljoin(ENSEMBL_GFF3_DIR, gff), FULL / gff)
    src["ucsc_chr22_fasta"] = download(UCSC_CHR22, FULL / "chr22.fa.gz")
    src["clinvar_vcf"]["file_date"] = vcf_header_value(FULL / "clinvar.vcf.gz", "fileDate")
    src["kgp_chr22_vcf"]["reference"] = vcf_header_value(FULL / kgp_vcf, "reference")

    log("== Counting records in the full chr22 sources")
    src["kgp_chr22_vcf"]["records"] = count_vcf(FULL / kgp_vcf)
    src["clinvar_vcf"]["records_chr22"] = count_vcf(FULL / "clinvar.vcf.gz", "22")
    log(f"  1000 Genomes chr22 records: {src['kgp_chr22_vcf']['records']:,}")
    log(f"  ClinVar chr22 records:      {src['clinvar_vcf']['records_chr22']:,}")

    log(f"== Cutting the development slice chr22:{start:,}-{end:,}")
    fx = manifest["fixtures"]
    tag = f"{start // 1000}k_{end // 1000}k"
    pairs = [
        ("kgp_vcf", FIXTURES / f"kgp_chr22_{tag}.vcf.gz", lambda d: slice_vcf(FULL / kgp_vcf, d, "chr22", start, end)),
        ("clinvar_vcf", FIXTURES / f"clinvar_22_{tag}.vcf.gz", lambda d: slice_vcf(FULL / "clinvar.vcf.gz", d, "22", start, end)),
        ("ensembl_genes", FIXTURES / f"ensembl_genes_22_{tag}.gff3.gz", lambda d: slice_gff3(FULL / gff, d, "22", start, end)),
        ("reference", FIXTURES / f"grch38_chr22_{tag}.fa", lambda d: slice_fasta(FULL / "chr22.fa.gz", d, start, end)),
    ]
    for key, dest, fn in pairs:
        n = fn(dest)
        fx[key] = {"path": str(dest.relative_to(ROOT)), "count": n, "sha256": sha256(dest)}
        log(f"  {dest.name}: {n:,}")
    samples_dest = FIXTURES / Path(KGP_SAMPLES).name
    shutil.copyfile(FULL / Path(KGP_SAMPLES).name, samples_dest)
    fx["kgp_samples"] = {"path": str(samples_dest.relative_to(ROOT)), "sha256": sha256(samples_dest)}
    genes_all = FULL / "ensembl_genes_22.gff3.gz"
    fx["ensembl_genes_chr22_all"] = {"path": str(genes_all.relative_to(ROOT)), "count": slice_gff3(FULL / gff, genes_all, "22")}

    if args.gnomad_schema:
        log("== gnomAD v3 BigQuery schema (metadata only, no query cost)")
        src["gnomad_v3_chr22_bigquery"] = gnomad_schema()

    SOURCES.mkdir(parents=True, exist_ok=True)
    out = SOURCES / "manifest.json"
    out.write_text(json.dumps(manifest, indent=2))
    log(f"\nDone. Manifest: {out.relative_to(ROOT)}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("Interrupted: run again to resume the download.")
