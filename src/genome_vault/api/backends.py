"""Query backends. The API's SQL is written once, with {t} where the table
prefix goes and @name parameters; each backend adapts it to its engine.

* DuckDBBackend reads the warehouse dbt builds locally and in CI.
* BigQueryBackend runs on Cloud Run against the gv dataset, with a per-query
  byte cap, a daily byte budget and job labels.
"""
from __future__ import annotations

import datetime as dt
import re
import threading
from collections import OrderedDict
from typing import Any, Protocol

PARAM = re.compile(r"@([a-z_][a-z0-9_]*)")


class BudgetExceeded(RuntimeError):
    """The API's daily BigQuery byte budget is spent."""


class Backend(Protocol):
    name: str

    def query(self, sql: str, params: dict[str, Any]) -> list[dict[str, Any]]: ...


class _Cache:
    """Small LRU cache of query results. The warehouse changes only when a
    build runs, and a new build means a new deployment, so results are cached
    for the life of the process."""

    def __init__(self, size: int) -> None:
        self.size = size
        self._d: OrderedDict[tuple, list[dict[str, Any]]] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key: tuple) -> list[dict[str, Any]] | None:
        with self._lock:
            if key in self._d:
                self._d.move_to_end(key)
                return self._d[key]
        return None

    def put(self, key: tuple, value: list[dict[str, Any]]) -> None:
        with self._lock:
            self._d[key] = value
            self._d.move_to_end(key)
            while len(self._d) > self.size:
                self._d.popitem(last=False)


def _key(sql: str, params: dict[str, Any]) -> tuple:
    return (sql, tuple(sorted(params.items())))


class DuckDBBackend:
    name = "duckdb"

    def __init__(self, path: str, cache_entries: int = 2048) -> None:
        import duckdb

        self._con = duckdb.connect(path, read_only=True)
        self._lock = threading.Lock()  # one DuckDB connection, shared by threads
        self._cache = _Cache(cache_entries)

    def query(self, sql: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        key = _key(sql, params)
        if (hit := self._cache.get(key)) is not None:
            return hit
        text = PARAM.sub(r"$\1", sql.replace("{t}", "main."))
        with self._lock:
            cur = self._con.execute(text, params)
            cols = [c[0] for c in cur.description]
            rows = [dict(zip(cols, r, strict=True)) for r in cur.fetchall()]
        self._cache.put(key, rows)
        return rows


class BigQueryBackend:
    name = "bigquery"

    def __init__(self, project: str, dataset: str, max_bytes_per_query: int, daily_bytes: int,
                 cache_entries: int = 2048, client: Any = None) -> None:
        from google.cloud import bigquery

        self._bq = bigquery
        self._client = client or bigquery.Client(project=project)
        self._prefix = f"`{project}.{dataset}`."
        self.max_bytes_per_query = max_bytes_per_query
        self.daily_bytes = daily_bytes
        self._cache = _Cache(cache_entries)
        self._lock = threading.Lock()
        self._day = dt.date.min
        self.bytes_billed_today = 0

    def _param(self, name: str, value: Any):
        kind = ("BOOL" if isinstance(value, bool) else "INT64" if isinstance(value, int)
                else "FLOAT64" if isinstance(value, float) else "STRING")
        return self._bq.ScalarQueryParameter(name, kind, value)

    def _spend(self, billed: int) -> None:
        with self._lock:
            today = dt.datetime.now(dt.UTC).date()
            if today != self._day:
                self._day, self.bytes_billed_today = today, 0
            self.bytes_billed_today += billed

    def budget_left(self) -> int:
        with self._lock:
            if dt.datetime.now(dt.UTC).date() != self._day:
                return self.daily_bytes
            return self.daily_bytes - self.bytes_billed_today

    def query(self, sql: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        key = _key(sql, params)
        if (hit := self._cache.get(key)) is not None:
            return hit
        if self.budget_left() <= 0:
            raise BudgetExceeded("the API's daily BigQuery budget is spent; try again after 00:00 UTC")
        config = self._bq.QueryJobConfig(
            query_parameters=[self._param(k, v) for k, v in params.items()],
            maximum_bytes_billed=self.max_bytes_per_query,
            labels={"app": "genome-vault-api"},
        )
        job = self._client.query(sql.replace("{t}", self._prefix), job_config=config)
        rows = [dict(r) for r in job.result()]
        self._spend(job.total_bytes_billed or 0)
        self._cache.put(key, rows)
        return rows
