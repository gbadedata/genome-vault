"""API settings, read from the environment once at start-up."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    backend: str = "duckdb"                  # duckdb (local, CI) or bigquery
    duckdb_path: str = "data/work/genome_vault.duckdb"
    project: str = "genome-vault-202605"
    dataset: str = "gv"
    max_bytes_per_query: int = 200_000_000   # BigQuery refuses a query that would bill more
    daily_bytes: int = 25_000_000_000        # 25 GB/day: 31 days stay inside the free 1 TB/month
    requests_per_minute: int = 60            # per client IP
    cache_entries: int = 2048
    code_version: str = "unknown"

    @classmethod
    def from_env(cls) -> Settings:
        e = os.environ
        return cls(
            backend=e.get("GV_API_BACKEND", cls.backend),
            duckdb_path=e.get("GV_DUCKDB", cls.duckdb_path),
            project=e.get("GV_PROJECT_ID", cls.project),
            dataset=e.get("GV_DATASET", cls.dataset),
            max_bytes_per_query=int(e.get("GV_API_MAX_BYTES_PER_QUERY", cls.max_bytes_per_query)),
            daily_bytes=int(e.get("GV_API_DAILY_BYTES", cls.daily_bytes)),
            requests_per_minute=int(e.get("GV_API_REQUESTS_PER_MINUTE", cls.requests_per_minute)),
            cache_entries=int(e.get("GV_API_CACHE_ENTRIES", cls.cache_entries)),
            code_version=e.get("GV_CODE_VERSION", cls.code_version),
        )
