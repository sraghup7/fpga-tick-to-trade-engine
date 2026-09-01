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
