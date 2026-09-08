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

Per-symbol (D47): classify() takes the event's slot first; steps s1-s6
single-symbol (slot 0) reproduce the original scalar semantics exactly,
steps s7-s9 assert the actual D47 fix -- two slots' hysteresis states must
be independent (the RTL regression for the same bug lives in
tb/tb_ml_policy.v).

Run: python sim/test_ml_golden_handcase.py
"""

from ml_golden import MLClassifier

failures = []


def check(label, actual, expected):
    if actual != expected:
        failures.append(f"{label}: got {actual!r}, expected {expected!r}")


m = MLClassifier(th_high=20, th_low=-20)
HEALTHY = dict(bid_valid=True, ask_valid=True, crossed=False, seq_gap=False)

# Step 1: all-zero features -> z = 0. First event, adverse_risk[0] resets to
# 0, and z = 0 is strictly between -20 and +20 (the hold band), so it holds
# 0. risk_level = clamp(0 >> 0) = 0.
r = m.classify(0, (0, 0, 0, 0, 0, 0, 0, 0), **HEALTHY)
check("s1.z", r.z, 0)
check("s1.risk", r.risk_level, 0)
check("s1.adverse", r.adverse_risk, 0)
check("s1.forced", r.safe_forced, False)

# Step 2: all-max-positive -> z = 8 * 127 = 1016 >= 20 -> adverse.
# risk_level = clamp(1016) = 255.
r = m.classify(0, (127, 127, 127, 127, 127, 127, 127, 127), **HEALTHY)
check("s2.z", r.z, 1016)
check("s2.risk", r.risk_level, 255)
check("s2.adverse", r.adverse_risk, 1)
check("s2.forced", r.safe_forced, False)

# Step 3 (hold zone, from adverse): all-zero again -> z = 0, strictly inside
# the band -> adverse_risk[0] HOLDS its current value of 1.
r = m.classify(0, (0, 0, 0, 0, 0, 0, 0, 0), **HEALTHY)
check("s3.z", r.z, 0)
check("s3.risk", r.risk_level, 0)
check("s3.adverse", r.adverse_risk, 1)
check("s3.forced", r.safe_forced, False)

# Step 4: all-max-negative -> z = 8 * (-128) = -1024 <= -20 -> benign.
# risk_level = clamp(-1024) = 0.
r = m.classify(0, (-128, -128, -128, -128, -128, -128, -128, -128), **HEALTHY)
check("s4.z", r.z, -1024)
check("s4.risk", r.risk_level, 0)
check("s4.adverse", r.adverse_risk, 0)
check("s4.forced", r.safe_forced, False)

# Step 5: mixed signs -> z = 10-20+30-40+50-60+70-80 = -40 <= -20 -> benign.
r = m.classify(0, (10, -20, 30, -40, 50, -60, 70, -80), **HEALTHY)
check("s5.z", r.z, -40)
check("s5.risk", r.risk_level, 0)
check("s5.adverse", r.adverse_risk, 0)
check("s5.forced", r.safe_forced, False)

# Step 6 (fail-safe): the same benign z = -40 vector, but the book is crossed
# -> adverse_risk[0] forced to 1 regardless of z.
r = m.classify(0, (10, -20, 30, -40, 50, -60, 70, -80),
               bid_valid=True, ask_valid=True, crossed=True, seq_gap=False)
check("s6.z", r.z, -40)
check("s6.adverse", r.adverse_risk, 1)
check("s6.forced", r.safe_forced, True)

# ---- D47 per-symbol isolation (docs/contracts/ml_policy_per_symbol.md) ----
# s6 left slot 0's adverse_risk at 1 (forced). The discriminator for a
# shared-scalar model is a hold-band event on a slot that has NEVER had an
# event: its own default is 0, but a shared register would hold slot 0's
# just-set 1.
# Step 7: slot 1's FIRST event, z = 0 in the hold band, healthy book. Slot
# 1 has never been seen, so adverse_risk[1] must be 0. (Pre-D47 scalar:
# reads the shared register = slot 0's 1 -> wrongly returns 1. This is the
# exact S0 cross-contamination the fix removes.)
r = m.classify(1, (0, 0, 0, 0, 0, 0, 0, 0), **HEALTHY)
check("s7.adverse", r.adverse_risk, 0)
check("s7.slot0_untouched", m.adverse_risk.get(0), 1)   # still 1 from s6

# Step 8: slot 0 hold-band event (z = 0): slot 0's own last value is 1 (s6),
# so it must hold 1 -- the hold reads the EVENT'S OWN slot's bit, which the
# s7 event on slot 1 must not have clobbered.
r = m.classify(0, (0, 0, 0, 0, 0, 0, 0, 0), **HEALTHY)
check("s8.adverse", r.adverse_risk, 1)
check("s8.slot1_still_0", m.adverse_risk.get(1), 0)

# Step 9: final per-slot state both directions -- slot 0 holds 1, slot 1
# holds 0. Only a per-symbol model can satisfy both simultaneously.
check("s9.slot0", m.adverse_risk.get(0), 1)
check("s9.slot1", m.adverse_risk.get(1), 0)

if failures:
    print(f"FAIL ({len(failures)} mismatch(es)):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)

print("PASS: hand-computed ML fallback case matches ml_golden.py exactly")
