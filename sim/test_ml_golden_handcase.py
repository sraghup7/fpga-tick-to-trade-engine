"""sim/test_ml_golden_handcase.py

Hand-computed check for sim/ml_golden.py (S6 fallback classifier), same
spirit as sim/test_feature_golden_handcase.py: every expected value below is
computed by hand in the comment above its assertion, not copied from a model
run. Uses the placeholder weights (w_i = 1 for all i, bias = 0) so z = sum of
the eight features and every value is simple addition.

The feature vectors and expected z values below are the SAME worked examples
used by tb/tb_ml_classifier_wrap.v (contract S3.4) and tb/tb_ml_policy.v
(S4.4), so this file and the two Verilog testbenches cross-check identical
numbers -- that is the "RTL == ml_golden.py bit-exact" gate S6 requires.

Thresholds th_high=20 / th_low=-20 throughout.

Run: python sim/test_ml_golden_handcase.py
"""

from ml_golden import MLClassifier

failures = []


def check(label, actual, expected):
    if actual != expected:
        failures.append(f"{label}: got {actual!r}, expected {expected!r}")


m = MLClassifier(th_high=20, th_low=-20)
HEALTHY = dict(bid_valid=True, ask_valid=True, crossed=False, seq_gap=False)

# Step 1: all-zero features -> z = 0. First event, adverse_risk resets to 0,
# and z = 0 is strictly between -20 and +20 (the hold band), so it holds 0.
# risk_level = clamp(0 >> 0) = 0.
r = m.classify((0, 0, 0, 0, 0, 0, 0, 0), **HEALTHY)
check("s1.z", r.z, 0)
check("s1.risk", r.risk_level, 0)
check("s1.adverse", r.adverse_risk, 0)
check("s1.forced", r.safe_forced, False)

# Step 2: all-max-positive -> z = 8 * 127 = 1016 >= 20 -> adverse.
# risk_level = clamp(1016) = 255.
r = m.classify((127, 127, 127, 127, 127, 127, 127, 127), **HEALTHY)
check("s2.z", r.z, 1016)
check("s2.risk", r.risk_level, 255)
check("s2.adverse", r.adverse_risk, 1)
check("s2.forced", r.safe_forced, False)

# Step 3 (hold zone, from adverse): all-zero again -> z = 0, strictly inside
# the band -> adverse_risk HOLDS its current value of 1.
r = m.classify((0, 0, 0, 0, 0, 0, 0, 0), **HEALTHY)
check("s3.z", r.z, 0)
check("s3.risk", r.risk_level, 0)
check("s3.adverse", r.adverse_risk, 1)
check("s3.forced", r.safe_forced, False)

# Step 4: all-max-negative -> z = 8 * (-128) = -1024 <= -20 -> benign.
# risk_level = clamp(-1024) = 0.
r = m.classify((-128, -128, -128, -128, -128, -128, -128, -128), **HEALTHY)
check("s4.z", r.z, -1024)
check("s4.risk", r.risk_level, 0)
check("s4.adverse", r.adverse_risk, 0)
check("s4.forced", r.safe_forced, False)

# Step 5: mixed signs -> z = 10-20+30-40+50-60+70-80 = -40 <= -20 -> benign.
r = m.classify((10, -20, 30, -40, 50, -60, 70, -80), **HEALTHY)
check("s5.z", r.z, -40)
check("s5.risk", r.risk_level, 0)
check("s5.adverse", r.adverse_risk, 0)
check("s5.forced", r.safe_forced, False)

# Step 6 (fail-safe): the same benign z = -40 vector, but the book is crossed
# -> adverse_risk forced to 1 regardless of z.
r = m.classify((10, -20, 30, -40, 50, -60, 70, -80),
               bid_valid=True, ask_valid=True, crossed=True, seq_gap=False)
check("s6.z", r.z, -40)
check("s6.adverse", r.adverse_risk, 1)
check("s6.forced", r.safe_forced, True)

if failures:
    print(f"FAIL ({len(failures)} mismatch(es)):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)

print("PASS: hand-computed ML fallback case matches ml_golden.py exactly")
