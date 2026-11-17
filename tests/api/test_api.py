"""The API against the warehouse dbt builds from the real slice
(chr22:42.05-42.25 Mb). Expected values come from the warehouse tables
themselves, queried directly, so these tests check the API's queries and
reshaping, not numbers chosen to pass. Needs the DuckDB file from `make slice`
(or the CI step that builds it); GV_DUCKDB points at it."""
from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import quote

import duckdb
import pytest
from fastapi.testclient import TestClient

from genome_vault.api.app import create_app
from genome_vault.api.backends import BudgetExceeded, DuckDBBackend
from genome_vault.api.config import Settings

pytestmark = pytest.mark.api

DB = os.environ.get("GV_DUCKDB", "data/work/genome_vault.duckdb")
NAGA_SNV = "chr22:42058350:G:A"  # rs5758566 in ClinVar, inside NAGA and WBP2NL


@pytest.fixture(scope="module")
def warehouse():
    if not Path(DB).exists():
        pytest.skip(f"{DB} not built: run make slice")
    con = duckdb.connect(DB, read_only=True)
    yield con
    con.close()


@pytest.fixture(scope="module")
def client(warehouse):
    settings = Settings(backend="duckdb", duckdb_path=DB, requests_per_minute=100_000, code_version="test")
    return TestClient(create_app(DuckDBBackend(DB), settings))


def scalar(con, sql, *params):
    return con.execute(sql, list(params)).fetchone()[0]


def test_health_does_not_need_the_warehouse():
    app = create_app(settings=Settings(backend="duckdb", duckdb_path="/nonexistent.duckdb", code_version="x"))
    r = TestClient(app).get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok"


def test_variant_lookup_matches_the_warehouse(client, warehouse):
    r = client.get(f"/variants/{NAGA_SNV}")
    assert r.status_code == 200
    v = r.json()
    assert (v["chrom"], v["pos"], v["ref"], v["alt"]) == ("chr22", 42058350, "G", "A")
    assert "NAGA" in v["genes"]
    assert v["clinvar"]["rsid"] == "rs5758566"
    key = scalar(warehouse, "select variant_key from main.dim_variant where variant_id = ?", NAGA_SNV)
    for pop in ("AFR", "AMR", "EAS", "EUR", "SAS"):
        af = scalar(warehouse, "select af_unrel from main.variant_population_freq where variant_key = ? and superpopulation = ?",
                    key, pop)
        assert v["frequencies"][pop]["af"] == pytest.approx(af)
        hwe = scalar(warehouse, "select hwe_p_unrel from main.qc_hardy_weinberg where variant_key = ? and superpopulation = ?",
                     key, pop)
        assert v["frequencies"][pop]["hwe_p_unrelated"] == pytest.approx(hwe)
    assert v["frequencies"]["basis"].startswith("2,504 unrelated")


def test_structural_variant_lookup(client, warehouse):
    vid = scalar(warehouse, "select variant_id from main.dim_variant where variant_class = 'SV' order by pos limit 1")
    r = client.get("/variants/" + quote(vid, safe=":"))
    assert r.status_code == 200
    assert r.json()["variant_id"] == vid and r.json()["class"] == "SV"


@pytest.mark.parametrize(("path", "status"), [
    ("/variants/chr22:1:A:G", 404),
    ("/variants/not-a-variant", 400),
    ("/variants?chrom=chr22&start=42050000", 400),
    ("/variants?chrom=chr22&start=42200000&end=42100000", 400),
    ("/variants?chrom=chr22&start=1&end=2000000", 400),
    ("/variants?rsid=12345", 400),
    ("/variants?chrom=chr22&start=1&end=10&limit=501", 422),
    ("/genes/NOT_A_GENE", 404),
    ("/samples/HG99999", 404),
    ("/samples/robert'); drop table students;--", 400),
])
def test_bad_requests_are_refused(client, path, status):
    assert client.get(path).status_code == status


def test_region_query_matches_the_warehouse(client, warehouse):
    start, end = 42126000, 42131000
    r = client.get(f"/variants?chrom=chr22&start={start}&end={end}&limit=500")
    assert r.status_code == 200
    body = r.json()
    expected = scalar(warehouse, "select count(*) from main.dim_variant where pos between ? and ?", start, end)
    assert body["count"] == expected
    positions = [v["pos"] for v in body["variants"]]
    assert positions == sorted(positions) and all(start <= p <= end for p in positions)


def test_flagged_only_returns_only_flagged_variants(client):
    body = client.get("/variants?chrom=chr22&start=42050000&end=42250000&flagged_only=true&limit=500").json()
    assert body["count"] > 0
    assert all(v["hwe_departure"] or v["gnomad_af_discordant"] for v in body["variants"])


def test_rsid_lookup(client):
    body = client.get("/variants?rsid=rs5758566").json()
    assert [v["variant_id"] for v in body["variants"]] == [NAGA_SNV]


def test_gene_variants_equal_the_bridge_table(client, warehouse):
    body = client.get("/genes/naga?limit=500").json()  # symbol lookup is case-insensitive
    assert body["gene"]["gene_symbol"] == "NAGA"
    expected = {r[0] for r in warehouse.execute("""
        select v.variant_id from main.bridge_variant_gene b
        join main.stg_genes g on g.gene_id = b.gene_id
        join main.dim_variant v on v.variant_key = b.variant_key
        where g.gene_symbol = 'NAGA'""").fetchall()}
    assert body["variants_overlapping"] == len(expected) < 500
    assert {v["variant_id"] for v in body["variants"]} == expected


def test_sample_lookup(client, warehouse):
    r = client.get("/samples/HG00096")
    assert r.status_code == 200
    s = r.json()
    assert s["population"] == scalar(warehouse, "select population from main.dim_sample where sample_id = 'HG00096'")
    assert set(s) >= {"flagged", "flagged_by_superpop", "het_hom_z", "het_hom_z_superpop"}


def test_qc_summary_reports_every_invariant_passing(client):
    body = client.get("/qc/summary").json()
    assert body["invariants_passed"] is True
    assert any(c["kind"] == "invariant" for c in body["checks"])


def test_findings_by_region(client):
    rows = client.get("/qc/findings-by-region").json()["rows"]
    assert {r["finding"] for r in rows} == {"hwe_departure", "gnomad_af_discordant", "common_but_absent_from_gnomad"}


def test_rate_limit_applies_per_client_but_not_to_health(warehouse):
    settings = Settings(backend="duckdb", duckdb_path=DB, requests_per_minute=2, code_version="test")
    c = TestClient(create_app(DuckDBBackend(DB), settings))
    codes = [c.get("/qc/summary", headers={"x-forwarded-for": "203.0.113.7"}).status_code for _ in range(3)]
    assert codes == [200, 200, 429]
    assert c.get("/qc/summary", headers={"x-forwarded-for": "203.0.113.8"}).status_code == 200
    assert c.get("/health", headers={"x-forwarded-for": "203.0.113.7"}).status_code == 200
    # a forged first address does not buy a fresh allowance: the last one counts
    assert c.get("/qc/summary", headers={"x-forwarded-for": "198.51.100.1, 203.0.113.7"}).status_code == 429


def test_spent_budget_returns_503():
    class Spent:
        name = "spent"

        def query(self, sql, params):
            raise BudgetExceeded("budget spent")

    c = TestClient(create_app(Spent(), Settings(code_version="test")))
    r = c.get("/qc/summary")
    assert r.status_code == 503 and "budget" in r.json()["detail"]
