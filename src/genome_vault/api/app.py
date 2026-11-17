"""genome-vault API: read-only lookups over the warehouse.

Run locally against the DuckDB warehouse that `make slice` builds:

    GV_API_BACKEND=duckdb GV_DUCKDB=data/work/genome_vault.duckdb \\
        uvicorn genome_vault.api.app:app --reload

On Cloud Run the backend is BigQuery (see infra/terraform/environments/dev/api.tf).
"""
from __future__ import annotations

import re
import threading
import time
from collections import defaultdict
from typing import Any

from fastapi import FastAPI, HTTPException, Path, Query, Request
from fastapi.responses import JSONResponse

from genome_vault.api import queries as q
from genome_vault.api.backends import Backend, BigQueryBackend, BudgetExceeded, DuckDBBackend
from genome_vault.api.config import Settings

POPULATIONS = ("AFR", "AMR", "EAS", "EUR", "SAS")
VARIANT_ID = re.compile(r"^(chr[0-9XYM]{1,2}):(\d{1,9}):\S+$")
RSID = re.compile(r"^rs\d{1,12}$")
SAMPLE_ID = re.compile(r"^[A-Z]{2}\d{5}$")
MAX_REGION_BP = 1_000_000
MAX_LIMIT = 500


def make_backend(settings: Settings) -> Backend:
    if settings.backend == "bigquery":
        return BigQueryBackend(settings.project, settings.dataset, settings.max_bytes_per_query,
                               settings.daily_bytes, settings.cache_entries)
    if settings.backend == "duckdb":
        return DuckDBBackend(settings.duckdb_path, settings.cache_entries)
    raise ValueError(f"unknown backend {settings.backend!r}")


class RateLimiter:
    """Token bucket per client IP, in memory. Cloud Run runs one instance
    (max_instance_count = 1), so this is the whole service's limit."""

    def __init__(self, per_minute: int) -> None:
        self.rate = per_minute / 60.0
        self.capacity = float(per_minute)
        self._buckets: dict[str, tuple[float, float]] = defaultdict(lambda: (self.capacity, time.monotonic()))
        self._lock = threading.Lock()

    def allow(self, client: str) -> bool:
        with self._lock:
            tokens, last = self._buckets[client]
            now = time.monotonic()
            tokens = min(self.capacity, tokens + (now - last) * self.rate)
            ok = tokens >= 1
            self._buckets[client] = (tokens - 1 if ok else tokens, now)
            return ok


def _genes(symbols: str | None) -> list[str]:
    return symbols.split("|") if symbols else []


def variant_summary(r: dict[str, Any]) -> dict[str, Any]:
    return {
        "variant_id": r["variant_id"],
        "pos": r["pos"],
        "ref": r["ref"],
        "alt": r["alt"],
        "class": r["variant_class"],
        "genes": _genes(r["gene_symbols"]),
        "region_class": r["region_class"],
        "af_all": r["af_all"],
        "hwe_departure": r["hwe_departure"],
        "gnomad_af_discordant": r["gnomad_af_discordant"],
        "clinical_significance": r["clinical_significance"],
    }


def variant_detail(r: dict[str, Any]) -> dict[str, Any]:
    basis = "2,504 unrelated phase 3 samples" if r["af_from_unrelated"] else "all 3,202 samples"
    return {
        "variant_id": r["variant_id"],
        "chrom": r["chrom"],
        "pos": r["pos"],
        "end": r["end_pos"],
        "ref": r["ref"],
        "alt": r["alt"],
        "class": r["variant_class"],
        "sv_type": r["sv_type"],
        "sv_len": r["sv_len"],
        "source_id": r["source_id"],
        "filter": r["filter_status"],
        "ref_check_grch38": r["ref_check"],
        "genes": _genes(r["gene_symbols"]),
        "in_protein_coding_gene": r["in_protein_coding_gene"],
        "region": {
            "class": r["region_class"],
            "segmental_duplication": r["in_segdup"],
            "low_mappability": r["in_low_mappability"],
            "tandem_repeat_or_homopolymer": r["in_tandem_repeat_or_homopolymer"],
            "any_giab_difficult": r["in_any_difficult"],
        },
        "frequencies": {
            "basis": basis,
            "allele_number_all": r["an_all"],
            "ALL": {"af": r["af_all"]},
            **{
                p: {
                    "af": r[f"af_{p.lower()}"],
                    "gnomad_af": r[f"gnomad_af_{p.lower()}"],
                    "hwe_p_unrelated": r[f"hwe_p_{p.lower()}"],
                }
                for p in POPULATIONS
            },
            "note": "gnomAD EUR is gnomAD's non-Finnish Europeans (nfe); 1000 Genomes EUR includes Finns.",
        },
        "gnomad_v3": {
            "found": r["in_gnomad"],
            "filter": r["gnomad_filter"],
            "alleles_at_site": r["gnomad_alleles_at_site"],
        },
        "qc": {
            "hwe_departure": r["hwe_departure"],
            "gnomad_af_discordant": r["gnomad_af_discordant"],
        },
        "clinvar": None if not r["in_clinvar"] else {
            "variation_id": r["clinvar_variation_id"],
            "rsid": r["rsid"],
            "clinical_significance": r["clinical_significance"],
            "review_status": r["clinvar_review_status"],
            "conditions": r["clinvar_conditions"],
            "molecular_consequence": r["clinvar_consequence"],
            "common_but_pathogenic": r["clinvar_common_but_pathogenic"],
        },
    }


def create_app(backend: Backend | None = None, settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    app = FastAPI(
        title="genome-vault API",
        version=settings.code_version,
        description=(
            "Read-only lookups over 1000 Genomes 30x chromosome 22 (3,202 samples), joined to ClinVar, "
            "Ensembl, gnomAD v3 and the GIAB difficult-region stratifications. Research data; "
            "not for clinical use."
        ),
    )
    state: dict[str, Any] = {"backend": backend}
    limiter = RateLimiter(settings.requests_per_minute)

    def db() -> Backend:
        if state["backend"] is None:  # connect on first use, not at import
            state["backend"] = make_backend(settings)
        return state["backend"]

    def run(sql: str, **params: Any) -> list[dict[str, Any]]:
        try:
            return db().query(sql, params)
        except BudgetExceeded as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc

    @app.middleware("http")
    async def rate_limit(request: Request, call_next):
        if request.url.path not in ("/health", "/docs", "/openapi.json"):
            # Cloud Run's front end appends the real client address last; anything
            # before it came from the client and can be forged.
            forwarded = request.headers.get("x-forwarded-for", "")
            client = forwarded.split(",")[-1].strip() or (request.client.host if request.client else "unknown")
            if not limiter.allow(client):
                return JSONResponse({"detail": "rate limit exceeded; slow down"}, status_code=429)
        return await call_next(request)

    @app.get("/", summary="Service information")
    def root() -> dict[str, Any]:
        return {
            "service": "genome-vault API",
            "code_version": settings.code_version,
            "docs": "/docs",
            "examples": ["/variants/chr22:42058350:G:A", "/variants?chrom=chr22&start=42126000&end=42131000",
                         "/variants?rsid=rs5758566", "/genes/NAGA", "/samples/HG00096", "/qc/summary"],
        }

    @app.get("/health", summary="Liveness (does not query the warehouse)")
    def health() -> dict[str, Any]:
        return {"status": "ok", "backend": settings.backend, "code_version": settings.code_version}

    @app.get("/variants/{variant_id}", summary="One variant, with frequencies, QC flags, region and ClinVar")
    def get_variant(variant_id: str = Path(..., examples=["chr22:42058350:G:A"])) -> dict[str, Any]:
        m = VARIANT_ID.match(variant_id)
        if not m:
            raise HTTPException(400, "variant_id must look like chr22:42058350:G:A")
        rows = run(q.VARIANT_BY_ID, chrom=m.group(1), pos=int(m.group(2)), variant_id=variant_id)
        if not rows:
            raise HTTPException(404, f"{variant_id} is not in the warehouse")
        return variant_detail(rows[0])

    @app.get("/variants", summary="Variants in a region, or by rsID")
    def list_variants(
        chrom: str = Query("chr22", pattern=r"^chr[0-9XYM]{1,2}$"),
        start: int | None = Query(None, ge=1),
        end: int | None = Query(None, ge=1),
        rsid: str | None = Query(None, description="e.g. rs5758566 (ClinVar rsIDs; the 1000 Genomes panel has none)"),
        flagged_only: bool = Query(False, description="only variants with an HWE departure or gnomAD discordance"),
        limit: int = Query(100, ge=1, le=MAX_LIMIT),
    ) -> dict[str, Any]:
        if rsid is not None:
            if not RSID.match(rsid):
                raise HTTPException(400, "rsid must look like rs5758566")
            rows = run(q.VARIANTS_BY_RSID, rsid=rsid)
            return {"rsid": rsid, "count": len(rows), "variants": [variant_summary(r) for r in rows]}
        if start is None or end is None:
            raise HTTPException(400, "give start and end (1-based, inclusive), or rsid")
        if end < start or end - start + 1 > MAX_REGION_BP:
            raise HTTPException(400, f"end must be >= start and the region at most {MAX_REGION_BP:,} bp")
        rows = run(q.VARIANTS_IN_REGION, chrom=chrom, start=start, end=end, flagged_only=flagged_only, limit=limit)
        return {"region": f"{chrom}:{start}-{end}", "count": len(rows), "limit": limit,
                "variants": [variant_summary(r) for r in rows]}

    @app.get("/genes/{symbol}", summary="A gene, and the variants that overlap it")
    def get_gene(symbol: str = Path(..., pattern=r"^[A-Za-z0-9._-]{1,40}$", examples=["NAGA"]),
                 limit: int = Query(100, ge=1, le=MAX_LIMIT)) -> dict[str, Any]:
        genes = run(q.GENE_BY_SYMBOL, symbol=symbol)
        if not genes:
            raise HTTPException(404, f"no Ensembl gene named {symbol} on chr22")
        g = genes[0]
        rows = [] if not g["variants"] else run(
            q.VARIANTS_IN_GENE, chrom=g["chrom"], first_pos=g["first_variant_pos"],
            gene_start=g["gene_start"], gene_end=g["gene_end"], limit=limit)
        return {
            "gene": {k: g[k] for k in ("gene_id", "gene_symbol", "biotype", "chrom", "gene_start", "gene_end", "strand")},
            "variants_overlapping": g["variants"],
            "returned": len(rows),
            "variants": [variant_summary(r) for r in rows],
        }

    @app.get("/samples/{sample_id}", summary="A 1000 Genomes sample: population, relatedness and QC")
    def get_sample(sample_id: str = Path(..., examples=["HG00096"])) -> dict[str, Any]:
        if not SAMPLE_ID.match(sample_id):
            raise HTTPException(400, "sample_id must look like HG00096 or NA12878")
        rows = run(q.SAMPLE, sample_id=sample_id)
        if not rows:
            raise HTTPException(404, f"{sample_id} is not one of the 3,202 samples")
        return rows[0]

    @app.get("/qc/summary", summary="Warehouse invariants and findings")
    def qc_summary() -> dict[str, Any]:
        rows = run(q.QC_SUMMARY)
        return {"invariants_passed": all(r["passed"] for r in rows if r["kind"] == "invariant"), "checks": rows}

    @app.get("/qc/findings-by-region", summary="QC findings by GIAB region class, with rate ratios")
    def findings_by_region() -> dict[str, Any]:
        return {"rows": run(q.FINDINGS_BY_REGION)}

    return app


app = create_app()
