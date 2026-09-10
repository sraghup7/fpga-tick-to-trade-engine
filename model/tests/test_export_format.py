"""weights.mem/bias.mem must be $readmemh-compatible hex (rtl/ml_classifier_wrap.v:59-60,
sim/ml_golden.py's _read_int8s/_read_int32) -- NOT decimal. Verified directly
against sim.ml_golden's own hex parser rather than re-deriving the format by
hand (docs/design_decisions.md D52).
"""
import os
import sys
import tempfile

import numpy as np

MODEL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(MODEL_DIR)
sys.path.insert(0, MODEL_DIR)
sys.path.insert(0, REPO_ROOT)

import train  # noqa: E402
from sim import ml_golden as rtl_ml_golden  # noqa: E402


def test_weights_and_bias_export_as_hex(tmp_path=None):
    tmp_dir = tmp_path or __import__("pathlib").Path(tempfile.mkdtemp())
    orig_model_dir = train.MODEL_DIR
    train.MODEL_DIR = tmp_dir
    try:
        weights_i8 = np.array([-13, -3, -3, -18, 5, -114, -29, 1], dtype=np.int8)
        bias_i32 = np.int32(61)
        train.export(
            offsets=np.zeros(8, dtype=np.int64),
            shifts=np.zeros(8, dtype=np.int64),
            weights_i8=weights_i8,
            bias_i32=bias_i32,
            t_high=10,
            t_low=5,
            threshold_source="precision_at_k",
            x_val_i8=np.zeros((1, 8), dtype=np.int8),
            z_val=np.array([0], dtype=np.int32),
            y_val=np.array([0], dtype=np.int8),
        )
        loaded_weights = rtl_ml_golden._read_int8s(str(tmp_dir / "weights.mem"))
        loaded_bias = rtl_ml_golden._read_int32(str(tmp_dir / "bias.mem"))
        assert loaded_weights == weights_i8.tolist(), (
            f"round-trip through sim.ml_golden's hex loader gave {loaded_weights}, "
            f"expected {weights_i8.tolist()}"
        )
        assert loaded_bias == int(bias_i32)
    finally:
        train.MODEL_DIR = orig_model_dir


def test_export_rejects_weights_violating_acc_w_bound():
    """model/train.py's export() must reject a weight/bias combination that
    would violate rtl/ml_classifier_wrap.v's ACC_W=20 accumulator bound
    (|bias| + SUM 128*|w_i| < 2**19) -- this is the Python-side half of the
    two-independent-guards requirement from docs/design_decisions.md D53;
    the RTL-side half is ml_classifier_wrap.v's own initial-block check.
    """
    import pytest

    # All 8 weights at the int8 extreme (-128) plus a large bias: clearly
    # violates the bound (8*128*128 + a huge bias is nowhere near 2**19... use
    # an intentionally-broken huge bias to force the violation unambiguously).
    weights_i8 = np.array([-128, -128, -128, -128, -128, -128, -128, -128], dtype=np.int8)
    bias_i32 = np.int32(2_000_000)  # forces |bias|+SUM128|w_i| well past 2**19

    with pytest.raises(ValueError, match=r"(?i)acc_w|bound|accumulator"):
        train.export(
            offsets=np.zeros(8, dtype=np.int64),
            shifts=np.zeros(8, dtype=np.int64),
            weights_i8=weights_i8,
            bias_i32=bias_i32,
            t_high=10,
            t_low=5,
            threshold_source="percentile_fallback_95",
            x_val_i8=np.zeros((1, 8), dtype=np.int8),
            z_val=np.array([0], dtype=np.int32),
            y_val=np.array([0], dtype=np.int8),
        )


if __name__ == "__main__":
    test_weights_and_bias_export_as_hex()
    print("PASS")
