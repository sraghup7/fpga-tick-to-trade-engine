#!/usr/bin/env python3
"""Convert model/golden_vectors.csv into $readmemh-compatible RTL stimulus
for tb/tb_ml_bit_exact.v (FR-34 / master spec T35_ml_bit_exact -- the
"hls4ml IP z == ml_golden.py for all golden vectors" gate, applied here to
the hand-written ml_classifier_wrap.v fallback since hls4ml hasn't run yet;
re-run this after any hls4ml IP swap, docs/design_decisions.md D52).

Run from the repo root:
    python scripts/gen_ml_bit_exact_vectors.py
"""
from __future__ import annotations

import csv
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = REPO_ROOT / "model" / "golden_vectors.csv"
OUT_DIR = REPO_ROOT / "sim" / "vectors"


def _hex_i8(v: int) -> str:
    return format(v & 0xFF, "02x")


def _hex_i32(v: int) -> str:
    return format(v & 0xFFFFFFFF, "08x")


def main() -> None:
    if not CSV_PATH.exists():
        raise SystemExit(f"{CSV_PATH} not found -- run model/train.py first")

    rows = []
    with CSV_PATH.open(newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    if not rows:
        raise SystemExit(f"{CSV_PATH} has no rows")

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    x_lines = []
    z_lines = []
    for row in rows:
        for i in range(8):
            x_lines.append(_hex_i8(int(row[f"x{i}"])))
        z_lines.append(_hex_i32(int(row["z"])))

    (OUT_DIR / "ml_bit_exact_x.mem").write_text("\n".join(x_lines) + "\n")
    (OUT_DIR / "ml_bit_exact_z.mem").write_text("\n".join(z_lines) + "\n")
    (OUT_DIR / "ml_bit_exact_count.vh").write_text(
        f"`define ML_BIT_EXACT_N {len(rows)}\n"
    )
    print(f"wrote {len(rows)} vectors to {OUT_DIR}")


if __name__ == "__main__":
    main()
