"""Chunked Parquet output, one directory per table.

Rows are buffered as column lists and flushed every `chunk_rows` rows, so a
full chromosome never has to fit in memory. Each table gets an explicit
Arrow schema: a column that changes type between chunks fails loudly instead
of producing files BigQuery or DuckDB would read inconsistently.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq


class TableWriter:
    def __init__(self, root: Path, name: str, schema: pa.Schema, chunk_rows: int = 2_000_000) -> None:
        self.dir = root / name
        self.dir.mkdir(parents=True, exist_ok=True)
        for old in self.dir.glob("part-*.parquet"):
            old.unlink()
        self.name = name
        self.schema = schema
        self.chunk_rows = chunk_rows
        self._cols: dict[str, list[Any]] = {f.name: [] for f in schema}
        self._arrays: dict[str, list[np.ndarray]] = {f.name: [] for f in schema}
        self._buffered = 0
        self._parts = 0
        self.rows = 0

    def append(self, row: dict[str, Any]) -> None:
        for k in self._cols:
            self._cols[k].append(row.get(k))
        self._buffered += 1
        self.rows += 1
        if self._buffered >= self.chunk_rows:
            self.flush()

    def append_arrays(self, arrays: dict[str, np.ndarray]) -> None:
        """Append many rows at once from equal-length numpy arrays (genotypes)."""
        n = len(next(iter(arrays.values())))
        if n == 0:
            return
        for k in self._arrays:
            self._arrays[k].append(arrays[k])
        self._buffered += n
        self.rows += n
        if self._buffered >= self.chunk_rows:
            self.flush()

    def flush(self) -> None:
        if self._buffered == 0:
            return
        cols = {}
        for f in self.schema:
            if self._arrays[f.name]:
                cols[f.name] = pa.array(np.concatenate(self._arrays[f.name]), type=f.type)
            else:
                cols[f.name] = pa.array(self._cols[f.name], type=f.type)
        table = pa.table(cols, schema=self.schema)
        pq.write_table(table, self.dir / f"part-{self._parts:05d}.parquet", compression="zstd")
        self._parts += 1
        self._buffered = 0
        self._cols = {f.name: [] for f in self.schema}
        self._arrays = {f.name: [] for f in self.schema}

    def close(self) -> int:
        self.flush()
        if self._parts == 0:  # always leave one file so readers see the schema
            pq.write_table(self.schema.empty_table(), self.dir / "part-00000.parquet")
        return self.rows
