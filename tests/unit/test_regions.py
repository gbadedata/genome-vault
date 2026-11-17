"""The GIAB region loader, on the committed real slices of the four
stratification BEDs (chr22:42.05-42.25 Mb)."""
from __future__ import annotations

import gzip
import hashlib

import duckdb
import pytest
from click.testing import CliRunner

from genome_vault.cli import main
from genome_vault.ingestion.regions import STRATIFICATIONS, read_bed

pytestmark = pytest.mark.unit

TAG = "22_42050k_42250k"


def bed(real, name):
    return real / f"giab_{name}_{TAG}.bed.gz"


@pytest.fixture(scope="module")
def regions_out(tmp_path_factory, real):
    out = tmp_path_factory.mktemp("regions")
    args = ["regions", "--out", str(out)]
    for name in STRATIFICATIONS:
        args += ["--bed", f"{name}={bed(real, name)}"]
    result = CliRunner().invoke(main, args, catch_exceptions=False)
    assert result.exit_code == 0, result.output
    return out


def q(out, sql):
    con = duckdb.connect()
    for name in ("genome_regions", "genome_region_sources"):
        con.sql(f"create view {name} as select * from read_parquet('{out / name}/*.parquet')")
    return con.sql(sql).fetchall()


def test_every_stratification_loaded(regions_out):
    got = {r[0] for r in q(regions_out, "select distinct stratification from genome_regions")}
    assert got == set(STRATIFICATIONS)


def test_sources_record_checksums_and_counts(regions_out, real):
    rows = q(regions_out, "select stratification, sha256, intervals_merged, bases from genome_region_sources")
    assert len(rows) == len(STRATIFICATIONS)
    for name, digest, merged, bases in rows:
        assert digest == hashlib.sha256(bed(real, name).read_bytes()).hexdigest()
        n, total = q(regions_out, f"""select count(*), sum(end_exclusive - start_0based)
                                      from genome_regions where stratification = '{name}'""")[0]
        assert (n, total) == (merged, bases)


def test_intervals_valid_sorted_and_disjoint(regions_out):
    bad = q(regions_out, """
        select count(*) from (
            select start_0based, end_exclusive,
                   lag(end_exclusive) over (partition by stratification order by start_0based) as prev_end
            from genome_regions
        ) where start_0based >= end_exclusive or start_0based <= prev_end""")[0][0]
    assert bad == 0


def test_merged_bases_never_exceed_raw_bases(real):
    for name in STRATIFICATIONS:
        merged, _ = read_bed(bed(real, name), "chr22")
        raw = 0
        with gzip.open(bed(real, name), "rt") as f:
            for line in f:
                cols = line.split("\t")
                raw += int(cols[2]) - int(cols[1])
        assert sum(e - s for s, e in merged) <= raw


def test_touching_and_overlapping_intervals_merge(tmp_path):
    # Merge rule edge cases: [10,20) and [20,30) touch; [25,40) overlaps; [50,60) stands alone.
    p = tmp_path / "edge.bed"
    p.write_text("chr22\t25\t40\nchr22\t10\t20\nchr22\t20\t30\nchr22\t50\t60\nchr21\t0\t5\n")
    merged, read = read_bed(p, "chr22")
    assert read == 4
    assert merged == [(10, 40), (50, 60)]


def test_unknown_stratification_rejected(real, tmp_path):
    result = CliRunner().invoke(main, ["regions", "--out", str(tmp_path), "--bed", f"segdups={bed(real, 'segdup')}"])
    assert result.exit_code != 0
    assert "NAME=PATH" in result.output
