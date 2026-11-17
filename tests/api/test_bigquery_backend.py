"""BigQueryBackend's cost guards, with a stand-in client: no network, no
credentials. Checks what the backend asks BigQuery to do."""
from __future__ import annotations

import pytest

pytest.importorskip("google.cloud.bigquery")

from genome_vault.api.backends import BigQueryBackend, BudgetExceeded  # noqa: E402

pytestmark = pytest.mark.api


class FakeJob:
    def __init__(self, rows, billed):
        self._rows, self.total_bytes_billed = rows, billed

    def result(self):
        return self._rows


class FakeClient:
    def __init__(self, billed=10_485_760):
        self.calls, self.billed = [], billed

    def query(self, sql, job_config):
        self.calls.append((sql, job_config))
        return FakeJob([{"n": 1}], self.billed)


def backend(client, daily=25_000_000_000):
    return BigQueryBackend("proj-x", "gv", max_bytes_per_query=200_000_000, daily_bytes=daily, client=client)


def test_queries_carry_the_cap_labels_typed_parameters_and_dataset():
    c = FakeClient()
    rows = backend(c).query("select * from {t}api_variant where chrom = @chrom and pos = @pos", {"chrom": "chr22", "pos": 5})
    assert rows == [{"n": 1}]
    sql, cfg = c.calls[0]
    assert "`proj-x.gv`.api_variant" in sql and "{t}" not in sql
    assert cfg.maximum_bytes_billed == 200_000_000
    assert cfg.labels == {"app": "genome-vault-api"}
    types = {p.name: p.type_ for p in cfg.query_parameters}
    assert types == {"chrom": "STRING", "pos": "INT64"}


def test_repeated_queries_are_served_from_cache():
    c = FakeClient()
    b = backend(c)
    for _ in range(3):
        b.query("select 1 from {t}qc_summary", {})
    assert len(c.calls) == 1


def test_daily_budget_stops_queries_once_spent():
    c = FakeClient(billed=10_485_760)
    b = backend(c, daily=20_000_000)  # room for two 10 MB queries
    b.query("select @a", {"a": 1})
    b.query("select @a", {"a": 2})
    with pytest.raises(BudgetExceeded):
        b.query("select @a", {"a": 3})
    assert b.bytes_billed_today == 2 * 10_485_760
