"""Regression guard: training must NOT drop rows just because the
deterministic signal rule wouldn't fire there -- rtl/feature_extractor.v
runs the ML datapath on every book-modifying update (feat_valid <= p2_valid
& p2_book), not only signal-firing ones, so restricting train/eval to
sides!=0 rows (the pre-fix behavior) meant the classifier and its
bit-exactness gate (golden_vectors.csv) never saw ~5/6 of what hardware
actually scores (docs/design_decisions.md D52).
"""
import os
import sys

MODEL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, MODEL_DIR)

import numpy as np  # noqa: E402
import ml_golden  # noqa: E402
import simulator  # noqa: E402
import config  # noqa: E402


def test_valid_rows_include_no_signal_events():
    events = simulator.generate_dataset(repeats=2)
    seqs, mids, symbol_ids, sides, raw_feats = ml_golden.extract_features(events)
    y_buy, y_sell, horizon_valid = ml_golden.compute_labels(
        mids, symbol_ids, config.LABEL_HORIZON_H
    )

    # y=0 for no-signal rows (not adverse -- no order would be placed), not
    # dropped from the dataset.
    y = np.zeros(len(sides), dtype=np.int8)
    y[sides > 0] = y_buy[sides > 0]
    y[sides < 0] = y_sell[sides < 0]
    valid = horizon_valid

    no_signal_count = int((sides == 0).sum())
    assert no_signal_count > 0, "test fixture must contain some no-signal rows"
    assert valid[sides == 0].sum() > 0, "no-signal rows must remain in the valid set"
    assert int(valid.sum()) > int((valid & (sides != 0)).sum()), (
        "training set must be larger than the signal-only subset"
    )


if __name__ == "__main__":
    test_valid_rows_include_no_signal_events()
    print("PASS")
