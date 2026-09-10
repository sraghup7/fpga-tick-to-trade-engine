"""Training + quantization pipeline (ml_engineer_brief.md SS3, SS6 Phase B, SS7.3).

The brief's quantization order (SS7.3) is:
  1. Train the floating-point baseline.
  2. Freeze feature definitions and preprocessing (normalization offsets/shifts).
  3. Quantize weights to int8, bias to int32.
  4. Re-evaluate on validation with exact fixed-point arithmetic (ml_golden.py,
     not the float model).
  5. Export weights, bias, offsets, shifts, thresholds, and golden vectors.
  6. After this point, do not change any arithmetic semantics.

We compute the normalization offsets/shifts (step 2) *before* training (step 1)
and train directly on the resulting (raw-offset)/2**shift scale, kept as float
(no int8 rounding yet). That is a deliberate reordering for a practical reason:
it means the learned float weights are already in the right numeric scale, so
"quantize the weights" (step 3) is a plain round-to-int8 with nothing to
rescale. The freeze-before-quantize *dependency* the brief actually cares
about (never change offsets/shifts after weights are quantized) is preserved.
"""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

import numpy as np
import tensorflow as tf

import config
import metrics
import ml_golden
import simulator

MODEL_DIR = Path(__file__).parent


def compute_normalization(raw_features: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """offset_i = round(mean(raw_i)); shift_i = smallest power-of-two shift
    such that +/- NORMALIZATION_SIGMA standard deviations of raw_i lands
    inside [-128, 127] (brief SS7.2 fixes the transform's *form*, not how
    offset/shift are derived from data -- see config.py's note).
    """
    means = raw_features.mean(axis=0)
    stds = raw_features.std(axis=0)
    offsets = np.round(means).astype(np.int64)
    shifts = np.zeros(config.NUM_FEATURES, dtype=np.int64)
    for i in range(config.NUM_FEATURES):
        half_range = max(config.NORMALIZATION_SIGMA * stds[i], 1.0)
        shift = 0
        while (half_range / (2**shift)) > config.FEATURE_MAX and shift < 30:
            shift += 1
        shifts[i] = shift
    return offsets, shifts


def chronological_split(
    symbol_ids: np.ndarray, train_fraction: float
) -> tuple[np.ndarray, np.ndarray]:
    """Per-symbol chronological split: within each symbol's contiguous,
    already-time-ordered block of rows, the first `train_fraction` go to
    train and the rest to validation. A single global time-ordered split
    would put entire scenarios only in train or only in validation (brief
    SS6's scenarios are each one symbol_id, run back-to-back) -- this way
    validation sees every scenario type, just its later portion in time.
    """
    train_idx, val_idx = [], []
    for sid in np.unique(symbol_ids):
        idx = np.where(symbol_ids == sid)[0]
        cut = int(len(idx) * train_fraction)
        train_idx.append(idx[:cut])
        val_idx.append(idx[cut:])
    return np.concatenate(train_idx), np.concatenate(val_idx)


def build_model() -> tf.keras.Model:
    """Dense(8->1), linear activation (brief SS3): the sigmoid is omitted
    because it's monotonic -- comparing z to a threshold is equivalent to
    comparing a probability to a probability threshold. We still train with
    a proper logistic loss by telling BinaryCrossentropy the model output is
    a logit (from_logits=True), so no Sigmoid layer needs to exist in the
    exported model.
    """
    model = tf.keras.Sequential(
        [
            tf.keras.layers.Input(shape=(config.NUM_FEATURES,)),
            tf.keras.layers.Dense(1, use_bias=True, activation="linear"),
        ]
    )
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=0.05),
        loss=tf.keras.losses.BinaryCrossentropy(from_logits=True),
    )
    return model


def threshold_rule_baseline(raw_features: np.ndarray) -> np.ndarray:
    """Phase B baseline #1 (brief SS6): a hand-tuned rule with no learned
    weights. Flags a quote as risky when the book is both notably lopsided
    (|F2| book imbalance in its top 30%) and notably volatile (F7 in its top
    30%) -- a simple stand-in for "don't trade into a one-sided, choppy book."
    """
    f2 = raw_features[:, 2]
    f7 = raw_features[:, 7]
    return (
        (np.abs(f2) > np.percentile(np.abs(f2), 70))
        & (f7 > np.percentile(f7, 70))
    ).astype(np.int8)


def pick_thresholds(z_val: np.ndarray, y_val: np.ndarray) -> tuple[int, int, str]:
    """T_high: the highest z-score cutoff (i.e. most conservative) that still
    achieves at least TARGET_PRECISION precision on the validation set, found
    by sweeping thresholds in descending-score order and taking cumulative
    precision. T_low sits HYSTERESIS_GAP below it (brief SS2/SS9.2: these are
    *recommended* values -- ml_policy.v in RTL owns the actual comparison and
    can retune them at runtime).

    Guard (docs/design_decisions.md D52): cumulative precision-at-k is only
    monotonically non-increasing in the well-behaved case. If the overall
    validation positive rate is itself >= TARGET_PRECISION, precision-at-k
    trivially clears the target almost everywhere (even for k=N, the full
    set) purely because the base rate does -- this carries no real
    discriminative signal and would otherwise let `hits[-1]` degenerate
    t_high toward z_val.min(), a risk gate that fires on almost every row.
    In that specific case, skip the precision-at-k search entirely and use
    the percentile fallback directly. This guard is targeted at the actual
    failure mode (base rate alone clearing the target) rather than an
    arbitrary restriction on the search range, so it does not affect any
    well-behaved case where the base rate is below target and precision-at-k
    genuinely, monotonically crosses the target partway through the sorted
    scores -- that search still runs over the FULL range unchanged.
    """
    order = np.argsort(-z_val)
    y_sorted = y_val[order]
    base_rate = float(y_val.mean())
    if base_rate >= config.TARGET_PRECISION:
        t_high = int(np.percentile(z_val, 95))
        source = "percentile_fallback_95"
    else:
        cum_tp = np.cumsum(y_sorted)
        cum_n = np.arange(1, len(y_sorted) + 1)
        precision_at_k = cum_tp / cum_n
        hits = np.where(precision_at_k >= config.TARGET_PRECISION)[0]
        if len(hits) > 0:
            t_high = int(z_val[order][hits[-1]])
            source = "precision_at_k"
        else:
            t_high = int(np.percentile(z_val, 95))
            source = "percentile_fallback_95"
    t_low = t_high - config.HYSTERESIS_GAP
    return t_high, t_low, source


def export(
    offsets: np.ndarray,
    shifts: np.ndarray,
    weights_i8: np.ndarray,
    bias_i32: int,
    t_high: int,
    t_low: int,
    threshold_source: str,
    x_val_i8: np.ndarray,
    z_val: np.ndarray,
    y_val: np.ndarray,
) -> None:
    model_config = {
        "status": (
            "TRAINED (S4 pipeline, model/train.py). Replaces the master "
            "spec Section 15 fallback placeholder (w_i=1, bias=0)."
        ),
        "notes": (
            "PROXY LABEL: 'adverse' means the synthetic proxy defined in "
            "ml_engineer_brief.md SS5 (mid moved >=1 tick against the "
            "quoted side within LABEL_HORIZON_H future events) -- this is "
            "NOT evidence about real market microstructure or real adverse "
            "selection; simulated trading only. If CFG_MIN_SPREAD/"
            "CFG_IMB_SHIFT (master spec SS9 registers 0x1C/0x20) are ever "
            "retuned at runtime away from the values recorded below, this "
            "model was trained against the OLD values and should be "
            "re-trained -- see docs/design_decisions.md D52."
        ),
        "features": [
            "F0_spread", "F1_mid_delta", "F2_imbalance", "F3_bid_chg",
            "F4_ask_chg", "F5_update_rate", "F6_last_trade_dir", "F7_volatility",
        ],
        "seed": config.SEED,
        "window_w": config.WINDOW_W,
        "window_includes_current": config.WINDOW_INCLUDES_CURRENT,
        "label_horizon_h": config.LABEL_HORIZON_H,
        "label_combine": config.LABEL_COMBINE,
        "cfg_min_spread": config.CFG_MIN_SPREAD,
        "cfg_imb_shift": config.CFG_IMB_SHIFT,
        "weight_quant_headroom": config.WEIGHT_QUANT_HEADROOM,
        "num_features": config.NUM_FEATURES,
        "feature_range": [config.FEATURE_MIN, config.FEATURE_MAX],
        "weight_range": [config.WEIGHT_MIN, config.WEIGHT_MAX],
        "accum_bits": config.ACCUM_BITS,
        "offsets": offsets.tolist(),
        "shifts": shifts.tolist(),
        "weights": [int(w) for w in weights_i8],
        "bias": int(bias_i32),
        "t_high": int(t_high),
        "t_low": int(t_low),
        "threshold_source": threshold_source,
        "versions": {
            "python": sys.version.split()[0],
            "numpy": np.__version__,
            "tensorflow": tf.__version__,
            "keras": tf.keras.__version__,
        },
    }
    (MODEL_DIR / "model_config.json").write_text(json.dumps(model_config, indent=2) + "\n")

    # $readmemh-compatible hex: rtl/ml_classifier_wrap.v:59-60 and
    # sim/ml_golden.py's _read_int8s/_read_int32 both parse these as
    # two's-complement hex, NOT decimal (docs/design_decisions.md D52 --
    # the pre-fix decimal export either fatal-errored $readmemh on the '-'
    # character or silently mis-parsed unsigned-looking values as hex).
    def _hex_i8(v: int) -> str:
        return format(int(v) & 0xFF, "02x")

    def _hex_i32(v: int) -> str:
        return format(int(v) & 0xFFFFFFFF, "08x")

    (MODEL_DIR / "weights.mem").write_text(
        "\n".join(_hex_i8(w) for w in weights_i8) + "\n"
    )
    (MODEL_DIR / "bias.mem").write_text(_hex_i32(bias_i32) + "\n")

    with (MODEL_DIR / "normalization.mem").open("w") as f:
        for o, s in zip(offsets.tolist(), shifts.tolist()):
            f.write(f"{o} {s}\n")
    (MODEL_DIR / "thresholds.mem").write_text(f"{int(t_high)} {int(t_low)}\n")

    adverse = (z_val >= t_high).astype(np.int8)
    with (MODEL_DIR / "golden_vectors.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([f"x{i}" for i in range(config.NUM_FEATURES)] + ["z", "adverse_risk", "label"])
        for row_x, z, a, y in zip(x_val_i8, z_val, adverse, y_val):
            writer.writerow(list(int(v) for v in row_x) + [int(z), int(a), int(y)])

    print(
        "\nexported model_config.json, weights.mem (hex), bias.mem (hex), "
        f"normalization.mem, thresholds.mem, golden_vectors.csv ({len(y_val)} rows) to {MODEL_DIR}"
    )


def main() -> None:
    print(
        f"seed={config.SEED} W={config.WINDOW_W} "
        f"(include_current={config.WINDOW_INCLUDES_CURRENT}) "
        f"H={config.LABEL_HORIZON_H} label_combine={config.LABEL_COMBINE}"
    )

    # Reproducibility (brief SS6: "a hard requirement") covers more than the
    # dataset -- Keras's own Dense-layer weight initializer draws from
    # TensorFlow's global RNG, which config.SEED does nothing to unless we
    # seed it explicitly. Without this, re-running train.py on the identical
    # dataset produced different float weights (and therefore different
    # quantized weights/thresholds/exported vectors) every time.
    tf.keras.utils.set_random_seed(config.SEED)

    events = simulator.generate_dataset()
    seqs, mids, symbol_ids, sides, raw_feats = ml_golden.extract_features(events)
    y_buy, y_sell, horizon_valid = ml_golden.compute_labels(mids, symbol_ids, config.LABEL_HORIZON_H)
    if config.LABEL_COMBINE != "SIDE_CONDITIONED":
        raise ValueError(f"unknown LABEL_COMBINE {config.LABEL_COMBINE!r}")
    # y_adverse = y_buy where the signal rule would buy, y_sell where it would
    # sell.
    # y=0 (not adverse) for rows where the signal rule wouldn't trade at all
    # -- these are still real events the RTL's ML datapath scores
    # continuously (feature_extractor.v runs on every book update, not only
    # signal-firing ones), so they must stay in the training/eval
    # distribution instead of being dropped (docs/design_decisions.md D52).
    # The label is only meaningful where a side would trade, so no-signal
    # rows get the well-defined negative label y=0 rather than being
    # excluded.
    y = np.zeros(len(sides), dtype=np.int8)
    y[sides > 0] = y_buy[sides > 0]
    y[sides < 0] = y_sell[sides < 0]
    valid = horizon_valid
    print(
        f"events with a trading signal: {(sides != 0).sum()} / {len(sides)}  "
        f"({(sides == 1).sum()} buy, {(sides == -1).sum()} sell)"
    )

    raw_feats, y, symbol_ids = raw_feats[valid], y[valid], symbol_ids[valid]
    print(f"labeled rows (in-horizon): {len(y)}  positive rate: {y.mean():.3f}")

    train_idx, val_idx = chronological_split(symbol_ids, config.TRAIN_FRACTION)
    print(f"train rows: {len(train_idx)}  val rows: {len(val_idx)}")

    # --- step 2 (computed first, see module docstring): normalization from TRAIN only ---
    offsets, shifts = compute_normalization(raw_feats[train_idx])
    print("offsets:", offsets.tolist())
    print("shifts: ", shifts.tolist())

    scale = 2.0 ** shifts.astype(np.float64)
    x_train_f = ((raw_feats[train_idx] - offsets) / scale).astype(np.float32)
    x_val_f = ((raw_feats[val_idx] - offsets) / scale).astype(np.float32)

    # --- step 1: train the floating-point baseline ---
    model = build_model()
    model.fit(
        x_train_f,
        y[train_idx].astype(np.float32),
        epochs=200,
        batch_size=64,
        verbose=0,
    )
    dense = model.layers[0]
    w_float, b_float = dense.get_weights()
    w_float = w_float.reshape(-1)
    b_float = float(b_float[0])
    print("float weights:", np.round(w_float, 3).tolist(), "bias:", round(b_float, 3))

    # --- step 3: quantize ---
    # Scale weights+bias together (same factor -> a pure positive rescale of
    # the logit, decision ranking preserved) so the largest weight actually
    # uses the int8 range instead of rounding to 0 (config.WEIGHT_QUANT_HEADROOM).
    max_abs_w = max(float(np.max(np.abs(w_float))), 1e-8)
    quant_scale = (config.WEIGHT_QUANT_HEADROOM * config.WEIGHT_MAX) / max_abs_w
    print(f"weight quant scale: {quant_scale:.2f}")

    weights_i8 = np.clip(
        np.round(w_float * quant_scale), config.WEIGHT_MIN, config.WEIGHT_MAX
    ).astype(np.int8)
    bias_i32 = np.int32(round(b_float * quant_scale))
    print("quantized weights:", weights_i8.tolist(), "bias:", int(bias_i32))

    # Diagnostic only (not exported): float-model AUC on the same validation
    # rows, to tell a quantization-loss problem apart from a task-ceiling one.
    z_val_float = model.predict(x_val_f, verbose=0).reshape(-1)
    float_auc = metrics.roc_auc(y[val_idx], z_val_float.astype(np.float64))
    print(f"[diagnostic] float-model roc_auc on validation: {float_auc:.3f}")

    # --- step 4: re-evaluate with EXACT fixed-point arithmetic (ml_golden), not the float model ---
    x_val_i8 = ml_golden.normalize(raw_feats[val_idx], offsets, shifts)
    z_val = ml_golden.classify(x_val_i8, weights_i8, int(bias_i32))

    t_high, t_low, threshold_source = pick_thresholds(z_val, y[val_idx])
    print(f"thresholds: T_high={t_high} T_low={t_low} source={threshold_source}")

    y_pred = (z_val >= t_high).astype(np.int8)
    adverse_risk = ml_golden.hysteresis_policy(z_val, symbol_ids[val_idx], t_high, t_low)

    # --- Phase B baselines (brief SS6) ---
    rule_pred = threshold_rule_baseline(raw_feats[val_idx])
    rule_report = metrics.report(y[val_idx], rule_pred)
    quant_report = metrics.report(y[val_idx], y_pred, scores=z_val.astype(np.float64))
    hyst_report = metrics.report(y[val_idx], adverse_risk)

    print()
    print(metrics.format_report("1. hand-tuned threshold rule", rule_report))
    print()
    print(metrics.format_report("3. quantized linear classifier (single threshold)", quant_report))
    print()
    print(metrics.format_report("3b. quantized linear classifier (with hysteresis)", hyst_report))
    print(
        "\nNOTE: 'adverse' here means the brief's synthetic proxy label "
        "(mid moved >=1 tick within H events) -- this is not evidence about "
        "real market microstructure, only a controlled test of the pipeline."
    )

    export(offsets, shifts, weights_i8, bias_i32, t_high, t_low, threshold_source, x_val_i8, z_val, y[val_idx])


if __name__ == "__main__":
    main()
