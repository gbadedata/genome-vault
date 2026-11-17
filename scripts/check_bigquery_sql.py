"""Parse every model and test that dbt compiled for BigQuery, using sqlglot's
BigQuery dialect. Catches DuckDB-only syntax before it reaches BigQuery.

Usage: python scripts/check_bigquery_sql.py warehouse/target-bq/compiled
"""
from __future__ import annotations

import sys
from pathlib import Path

import sqlglot
from sqlglot.errors import ParseError


def main(root: str) -> int:
    files = sorted(Path(root).rglob("*.sql"))
    if not files:
        print(f"no compiled SQL under {root}")
        return 1
    errors = 0
    for f in files:
        try:
            sqlglot.parse(f.read_text(), read="bigquery", error_level=sqlglot.ErrorLevel.RAISE)
        except ParseError as exc:
            errors += 1
            print(f"{f}: {str(exc)[:300]}")
    print(f"parsed {len(files)} compiled files as BigQuery SQL: {errors} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "warehouse/target-bq/compiled"))
