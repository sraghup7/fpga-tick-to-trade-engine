"""sim/ml_golden.py

Bit-exact Python reference for the S6 ML fallback classifier -- the combined
behavior of rtl/ml_classifier_wrap.v + rtl/ml_policy.v (contract
docs/contracts/ml_integration.md S5). Written from the spec, not the RTL, per
S11.1. One `MLClassifier` object holds the persisting hysteresis state and is
called once per ML event (one per feature vector), matching ml_policy.v's
registered `adverse_risk` exactly.

Weights/bias are loaded from model/weights.mem / model/bias.mem -- the SAME
placeholder files the RTL loads via $readmemh -- so this stays bit-exact even
if the placeholder values ever change. They are NOT trained (S4 has not run);
they are the master-spec S15 fallback (w_i = 1 for all i, bias = 0), chosen so
every vector is trivially hand-computable. This is a documented placeholder,
not a claim of predictive power.

Arithmetic correspondence (bit-exact):
  * z = bias + sum(w_i * x_i), plain Python ints -- no saturation needed at
    these magnitudes (max |z| with placeholder weights is 8*128 = 1024).
  * risk_level = clamp((z + score_offset) >> score_shift, 0, 255), using
    Python's native >> which floors toward negative infinity on a signed int
    -- the same semantics as the RTL's >>> sign-extending arithmetic shift
    (the correspondence feature_golden.py/feature_normalizer.v already rely
    on).
  * Hysteresis + fail-safe forcing transcribed directly from ml_policy.v's
    always block: adverse sets on z >= th_high, clears on z <= th_low, holds
    in between; invalid side / crossed / seq_gap forces adverse regardless.
"""

from __future__ import annotations

from dataclasses import dataclass


def _read_int8s(path: str) -> list[int]:
    vals = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            v = int(line, 16)
            if v >= 0x80:
                v -= 0x100
            vals.append(v)
    return vals


def _read_int32(path: str) -> int:
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            v = int(line, 16)
            if v >= 0x80000000:
                v -= 0x100000000
            return v
    return 0


@dataclass
class MLResult:
    z: int
    risk_level: int
    adverse_risk: int
    safe_forced: bool


class MLClassifier:
    """Bit-exact reference for ml_classifier_wrap.v + ml_policy.v (S6
    fallback). Weights/bias loaded from model/weights.mem, model/bias.mem --
    the same placeholder files the RTL loads via $readmemh, so this stays
    bit-exact even if the placeholder values ever change."""

    def __init__(self, th_high: int, th_low: int,
                 score_offset: int = 0, score_shift: int = 0,
                 weights_path: str = "model/weights.mem",
                 bias_path: str = "model/bias.mem"):
        self.weights = _read_int8s(weights_path)
        self.bias = _read_int32(bias_path)
        if len(self.weights) != 8:
            raise ValueError(f"expected 8 weights, got {len(self.weights)}")
        self.th_high = th_high
        self.th_low = th_low
        self.score_offset = score_offset
        self.score_shift = score_shift
        self.adverse_risk = 0   # persisting hysteresis state, reset default

    def classify(self, features: tuple[int, ...],
                 bid_valid: bool, ask_valid: bool,
                 crossed: bool, seq_gap: bool) -> MLResult:
        """One classifier event. Updates self.adverse_risk in place
        (hysteresis persists across calls, matching ml_policy.v's registered
        state) and returns the full verdict for this event."""
        z = self.bias + sum(w * x for w, x in zip(self.weights, features))

        shifted = (z + self.score_offset) >> self.score_shift   # floor >>, == RTL >>>
        risk_level = max(0, min(255, shifted))

        safe_state = (not bid_valid) or (not ask_valid) or crossed or seq_gap
        if safe_state:
            adverse = 1
            safe_forced = True
        elif z >= self.th_high:
            adverse = 1
            safe_forced = False
        elif z <= self.th_low:
            adverse = 0
            safe_forced = False
        else:
            adverse = self.adverse_risk   # hysteresis hold
            safe_forced = False

        self.adverse_risk = adverse
        return MLResult(z, risk_level, adverse, safe_forced)
