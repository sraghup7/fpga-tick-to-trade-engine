"""Frozen semantic constants shared by simulator.py, ml_golden.py, and train.py.

These decisions come from ml_engineer_brief.md SS4 (features), SS5 (label), and
SS7 (fixed-point contract). Once golden vectors are exported (train.py step 5,
brief SS7.3), do not change any value here -- it invalidates every vector and
breaks bit-exact agreement with the RTL.
"""

# Dataset seed. Recorded in every results file (brief SS6) so the dataset is
# reproducible from this one number.
SEED = 20260901

# --- Feature window (F5 update rate, F7 volatility), brief SS4 ---
# Allowed values: 4, 8, 16, 32.
WINDOW_W = 16
# Whether the current event counts toward its own window (brief SS4: "Decide
# whether the current event is included in the window ... and write it down").
WINDOW_INCLUDES_CURRENT = True

# --- Label horizon, brief SS5 ---
# Number of subsequent market-data *events* (not wall-clock time). Allowed: 20, 50, 100.
LABEL_HORIZON_H = 50

# --- Fixed-point formats, brief SS7.1 ---
NUM_FEATURES = 8
FEATURE_MIN, FEATURE_MAX = -128, 127     # signed int8 normalized feature range
WEIGHT_MIN, WEIGHT_MAX = -128, 127       # signed int8 weight range
ACCUM_BITS = 32                          # signed int32 accumulator/score z

# Raw-feature clip applied before normalization, purely to keep F5/F7 (which
# are unbounded sums over the window) inside a sane, documented range. This is
# a raw-domain clip, independent of the int8 saturation applied in SS7.2.
RAW_FEATURE_CLIP = 32767

# --- Training-time decisions (brief SS3/SS6/SS7.3), frozen the same way ---
#
# CHANGED at CHECKPOINT 1.1 (2026-09-09): the original choice here was
# LABEL_COMBINE = "OR" (y_adverse = y_buy | y_sell -- "the market moved >=1
# tick in EITHER direction"). That turned out to be structurally degenerate:
# for any noisy random walk, delta==0 over H=50 events essentially never
# happens, so OR(y_buy, y_sell) covers "the price moved at all" and is true
# ~97% of the time. Training on it collapsed to a constant predictor (all 8
# weights rounded to 0, bias alone driving a 99.7%-precision "always adverse"
# classifier, ROC-AUC=0.500 -- zero discriminative power). Caught by actually
# running train.py, not by inspection.
#
# The real problem was conceptual, not just statistical: a buy is only
# adversely selected if price *drops*; a sell only if price *rises*. OR-ing
# the two ignores which side would even be traded. SIDE_CONDITIONED fixes
# this by first computing which side (if any) the master spec's actual
# decision rule (FR-35/FR-36, master spec SS6.6) would trade at this event --
# buy if spread >= CFG_MIN_SPREAD and bid_qty > (ask_qty << CFG_IMB_SHIFT),
# sell under the mirrored condition, else no signal -- and then using y_buy
# for rows where the rule would buy, y_sell where it would sell, and
# excluding rows where the rule wouldn't trade at all (gate 0x09 is moot if
# no order is ever placed). See ml_golden.intended_side().
LABEL_COMBINE = "SIDE_CONDITIONED"

# Signal-rule thresholds (master spec SS9 register map defaults: MIN_SPREAD
# 0x1C = 2, IMB_SHIFT 0x20 = 1) used only to decide which label applies to
# each row -- not otherwise part of the classifier's own arithmetic contract.
CFG_MIN_SPREAD = 2
CFG_IMB_SHIFT = 1

# Added at CHECKPOINT 1.1 alongside SIDE_CONDITIONED: with CFG_IMB_SHIFT=1 a
# signal only fires when one side's size is more than double the other's,
# which the original 7-scenario, ~1160-event dataset only did 174 times --
# too few rows (120 train / 54 val) to train or evaluate reliably (observed
# ROC-AUC=0.387, i.e. noise, not signal). SCENARIO_REPEATS runs the full
# scenario set this many times over (each repeat = fresh symbol_ids, still
# one deterministic draw from the seeded rng, so the whole dataset stays
# reproducible from SEED alone) to get enough signal-bearing rows.
SCENARIO_REPEATS = 20

# Train/validation split (chronological, not shuffled, so validation always
# tests on "the future" relative to training -- shuffling would leak
# window/label information across the split boundary).
TRAIN_FRACTION = 0.7

# Normalization parameter derivation (brief SS7.2 fixes the *form*
# `saturate((raw-offset)>>shift)`; it does not fix how offset/shift are
# chosen from data). offset_i = round(mean(raw_i)) on the training split.
# shift_i is the smallest power-of-two shift such that +/- NORMALIZATION_SIGMA
# standard deviations of the training data lands inside [-128, 127] -- i.e.
# most in-distribution values use the full int8 range without saturating.
NORMALIZATION_SIGMA = 6.0

# Hysteresis thresholds (brief SS9.2: "recommended T_high/T_low") are chosen
# from the validation-set score distribution: T_high is the z-score threshold
# hitting TARGET_PRECISION precision on the adverse class; T_low is set
# HYSTERESIS_GAP below it so the flag doesn't chatter right at the boundary.
TARGET_PRECISION = 0.6
HYSTERESIS_GAP = 4

# Weight-quantization scale (found necessary at CHECKPOINT 1.1, roadmap step
# 6): the float baseline converges to weights well under 1.0 in magnitude
# (features are already scaled large by normalize(), so small weights are
# enough), and naively rounding those to the nearest int8 sends every single
# weight to 0 -- a completely dead classifier (z constant, ROC-AUC=0.5).
# Symmetric max-abs scaling fixes this: multiply every weight (and the bias,
# by the same factor, to keep the decision function a pure monotonic rescale
# of the original) so the largest-magnitude weight lands at
# WEIGHT_QUANT_HEADROOM * WEIGHT_MAX, i.e. actually uses the int8 range
# instead of a sliver of it near zero.
WEIGHT_QUANT_HEADROOM = 0.9
