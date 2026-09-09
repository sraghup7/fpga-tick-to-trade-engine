"""Regression guard: the exported golden_vectors.csv + model_config.json must
be exactly reproducible by feeding golden_vectors.csv's own x0..x7 columns
through ml_golden.classify() with model_config.json's weights/bias.

This doesn't re-verify the *hls4ml* IP (that's brief SS8.3, needs the IP
built) -- it only guards against train.py's export step silently drifting
from ml_golden.py, e.g. if someone edits one and forgets the other. Skips
cleanly if train.py hasn't been run yet (these files are generated, not
checked in raw -- see model_config.json/*.mem/*.csv being train.py output).
"""
import csv
import json
import os
import sys

import numpy as np
import pytest

MODEL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, MODEL_DIR)

import ml_golden  # noqa: E402

CONFIG_PATH = os.path.join(MODEL_DIR, "model_config.json")
VECTORS_PATH = os.path.join(MODEL_DIR, "golden_vectors.csv")

pytestmark = pytest.mark.skipif(
    not (os.path.exists(CONFIG_PATH) and os.path.exists(VECTORS_PATH)),
    reason="run train.py first to generate model_config.json / golden_vectors.csv",
)


def _load():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    rows = []
    with open(VECTORS_PATH, newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return cfg, rows


def test_exported_z_matches_ml_golden_classify():
    cfg, rows = _load()
    weights = np.array(cfg["weights"], dtype=np.int8)
    bias = int(cfg["bias"])

    x = np.array([[int(row[f"x{i}"]) for i in range(8)] for row in rows], dtype=np.int8)
    z_expected = np.array([int(row["z"]) for row in rows], dtype=np.int32)

    z_actual = ml_golden.classify(x, weights, bias)
    assert np.array_equal(z_actual, z_expected)


def test_exported_adverse_risk_matches_threshold():
    cfg, rows = _load()
    t_high = int(cfg["t_high"])
    z = np.array([int(row["z"]) for row in rows], dtype=np.int32)
    adverse_expected = np.array([int(row["adverse_risk"]) for row in rows], dtype=np.int8)
    adverse_actual = (z >= t_high).astype(np.int8)
    assert np.array_equal(adverse_actual, adverse_expected)


def test_weights_and_offsets_shapes_consistent():
    cfg, _ = _load()
    assert len(cfg["weights"]) == cfg["num_features"] == 8
    assert len(cfg["offsets"]) == len(cfg["shifts"]) == 8
    for w in cfg["weights"]:
        assert cfg["weight_range"][0] <= w <= cfg["weight_range"][1]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
