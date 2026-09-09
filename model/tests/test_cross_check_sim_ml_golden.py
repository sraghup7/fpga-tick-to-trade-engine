"""Regression guard (docs/design_decisions.md D52): model/ml_golden.py's
classify() and sim/ml_golden.py's MLClassifier -- two independently
maintained modules computing the same z = bias + sum(w_i*x_i) arithmetic --
must agree on every exported golden vector. Catches future drift between
the two the same 2026-09-09 review found had already happened once
(the pre-fix window/label bugs existed only on the model/ side).
"""
import csv
import importlib.util
import json
import os
import sys

import numpy as np
import pytest

MODEL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(MODEL_DIR)
sys.path.insert(0, MODEL_DIR)

import ml_golden  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "_rtl_ml_golden", os.path.join(REPO_ROOT, "sim", "ml_golden.py")
)
_rtl_ml_golden = importlib.util.module_from_spec(_spec)
sys.modules["_rtl_ml_golden"] = _rtl_ml_golden  # register before exec_module
_spec.loader.exec_module(_rtl_ml_golden)

CONFIG_PATH = os.path.join(MODEL_DIR, "model_config.json")
VECTORS_PATH = os.path.join(MODEL_DIR, "golden_vectors.csv")

pytestmark = pytest.mark.skipif(
    not (os.path.exists(CONFIG_PATH) and os.path.exists(VECTORS_PATH)),
    reason="run train.py first to generate model_config.json / golden_vectors.csv",
)


def test_sim_ml_golden_agrees_with_model_ml_golden():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    import csv
    rows = []
    with open(VECTORS_PATH, newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)

    clf = _rtl_ml_golden.MLClassifier(
        th_high=cfg["t_high"], th_low=cfg["t_low"],
        weights_path=os.path.join(MODEL_DIR, "weights.mem"),
        bias_path=os.path.join(MODEL_DIR, "bias.mem"),
    )
    weights = np.array(cfg["weights"], dtype=np.int8)
    bias = int(cfg["bias"])
    x = np.array([[int(row[f"x{i}"]) for i in range(8)] for row in rows], dtype=np.int8)
    z_model = ml_golden.classify(x, weights, bias)

    for i, row in enumerate(rows):
        features = tuple(int(row[f"x{i}"]) for i in range(8))
        result = clf.classify(
            slot=0, features=features,
            bid_valid=True, ask_valid=True, crossed=False, seq_gap=False,
        )
        assert result.z == int(z_model[i]), f"row {i}: sim.z={result.z} model.z={z_model[i]}"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
