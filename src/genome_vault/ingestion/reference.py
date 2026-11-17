"""GRCh38 reference sequence access for REF-allele checks.

Holds one contig (or one slice of a contig) in memory: chr22 is about 51 Mb,
small enough to keep as a string. Accepts plain or gzip-compressed FASTA.
A slice FASTA written by scripts/fetch_sources.py has a header like
'>chr22:42050000-42250000' and is positioned with its offset.
"""
from __future__ import annotations

import gzip
import re
from dataclasses import dataclass
from pathlib import Path

HEADER = re.compile(r"^>(?P<contig>[^\s:]+)(?::(?P<start>\d+)-(?P<end>\d+))?")


@dataclass(frozen=True)
class Reference:
    contig: str
    start: int  # 1-based position of the first base held
    sequence: str

    @classmethod
    def from_fasta(cls, path: str | Path) -> Reference:
        path = Path(path)
        opener = gzip.open if path.suffix == ".gz" else open
        with opener(path, "rt") as f:
            header = f.readline().strip()
            m = HEADER.match(header)
            if not m:
                raise ValueError(f"Unrecognised FASTA header in {path}: {header[:80]!r}")
            seq = "".join(line.strip() for line in f if not line.startswith(">"))
        start = int(m.group("start")) if m.group("start") else 1
        return cls(contig=m.group("contig"), start=start, sequence=seq.upper())

    @property
    def end(self) -> int:
        return self.start + len(self.sequence) - 1

    def check_ref(self, contig: str, pos: int, ref: str) -> str:
        """'match' or 'mismatch' against GRCh38 at contig:pos, or 'unchecked'
        when the allele is not covered by the sequence held (another contig,
        or a record that runs past the edge of a slice). 'N' in the reference
        matches any base (assembly gaps)."""
        first = pos - self.start
        last = first + len(ref)
        if contig != self.contig or first < 0 or last > len(self.sequence):
            return "unchecked"
        expected = self.sequence[first:last]
        for want, got in zip(expected, ref.upper(), strict=True):
            if want != "N" and want != got:
                return "mismatch"
        return "match"
