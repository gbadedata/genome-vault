from __future__ import annotations

from pathlib import Path

import pytest

REAL = Path(__file__).parent / "fixtures" / "real"


@pytest.fixture(scope="session")
def real() -> Path:
    return REAL


@pytest.fixture(scope="session")
def loaded(tmp_path_factory: pytest.TempPathFactory, real: Path) -> Path:
    """Run the full loader once on the committed real slice."""
    from click.testing import CliRunner

    from genome_vault.cli import main

    out = tmp_path_factory.mktemp("parquet")
    args = [
        "load",
        "--kgp-vcf", str(real / "kgp_chr22_42050k_42250k.vcf.gz"),
        "--clinvar", str(real / "clinvar_22_42050k_42250k.vcf.gz"),
        "--genes", str(real / "ensembl_genes_22_42050k_42250k.gff3.gz"),
        "--samples", str(real / "20130606_g1k_3202_samples_ped_population.txt"),
        "--reference", str(real / "grch38_chr22_42050k_42250k.fa"),
        "--out", str(out),
    ]
    panel = real / "integrated_call_samples_v3.20130502.ALL.panel"
    if panel.exists():
        args[-2:-2] = ["--unrelated-panel", str(panel)]
    result = CliRunner().invoke(main, args, catch_exceptions=False)
    assert result.exit_code == 0, result.output
    return out
