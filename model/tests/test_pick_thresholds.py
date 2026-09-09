"""pick_thresholds must never degenerate to (near) the minimum validation
z-score -- if the overall validation positive rate happens to be >=
TARGET_PRECISION, cumulative precision-at-k can re-cross the target near
k=N (all rows), which the unguarded version accepted (docs/design_decisions.md D52).
"""
import os
import sys

MODEL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, MODEL_DIR)

import numpy as np  # noqa: E402
import config  # noqa: E402
import train  # noqa: E402


def test_pick_thresholds_does_not_degenerate_to_minimum():
    rng = np.random.default_rng(0)
    n = 1000
    # Positive rate ~= 0.7, ABOVE config.TARGET_PRECISION (0.6) -- the
    # degenerate-trigger condition -- with z uncorrelated with y (worst case:
    # no real signal, so precision-at-k is flat around the base rate for
    # every k, including k=N).
    y_val = (rng.random(n) < 0.7).astype(np.int8)
    z_val = rng.integers(-50, 50, size=n).astype(np.int32)

    t_high, t_low = train.pick_thresholds(z_val, y_val)

    assert t_high > int(np.min(z_val)), (
        f"t_high={t_high} degenerated to (near) the minimum z={z_val.min()}"
    )


if __name__ == "__main__":
    test_pick_thresholds_does_not_degenerate_to_minimum()
    print("PASS")
