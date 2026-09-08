"""sim/ml_golden.py

Bit-exact Python reference for the S6 ML fallback classifier (master spec
§5.4 model spec, §9 register map, FR-26/27/28/29/31/33) -- what
rtl/ml_classifier_wrap.v + rtl/ml_policy.v are contracted to implement.
Derived directly from those spec clauses, not from either RTL file --
re-derived and cross-checked against the spec text alone in
docs/design_decisions.md D31 after an earlier version of this docstring
wrongly credited ml_policy.v's own always block as the source for the
hysteresis/fail-safe logic below (a real violation of CLAUDE.md's "golden
models are written from the spec, not the RTL" rule, even though the
resulting arithmetic turned out to already be correct: a model that
matches the RTL because it was copied from the RTL proves nothing about
whether the RTL itself is right). One `MLClassifier` object holds the
persisting hysteresis state and is called once per ML event (one per
feature vector, FR-30's fixed-depth-pipeline framing), matching
ml_policy.v's registered `adverse_risk` exactly.

Weights/bias are loaded from model/weights.mem / model/bias.mem -- the SAME
placeholder files the RTL loads via $readmemh -- so this stays bit-exact even
if the placeholder values ever change. They are NOT trained (S4 has not run);
they are the master-spec S15 fallback (w_i = 1 for all i, bias = 0), chosen so
every vector is trivially hand-computable. This is a documented placeholder,
not a claim of predictive power.

Arithmetic correspondence (bit-exact), each traced to its own spec clause:
  * z = bias + sum(w_i * x_i) (§5.4, FR-27's int8*int8->int32 accumulation),
    plain Python ints -- no saturation needed at these magnitudes (max |z|
    with placeholder weights is 8*128 = 1024, nowhere near int32 range).
  * risk_level = clamp((z + score_offset) >> score_shift, 0, 255) -- §9's
    literal ML_SCORE_OFFSET/ML_SCORE_SHIFT register definitions ("risk_level
    = (z + offset) >> shift"), §5.4's "risk_level | unsigned 8-bit |
    saturate((z + offset) >> shift)" row. Python's native >> floors toward
    negative infinity on a signed int -- the same semantics as a sign-
    extending arithmetic shift (the correspondence feature_golden.py/
    feature_normalizer.v already rely on).
  * Hysteresis (FR-28/29): adverse sets on z >= th_high, clears on
    z <= th_low, holds in between (T_high > T_low is a runtime-configured
    invariant, not re-derived here).
  * Fail-safe forcing (FR-26/31): a side being invalid, the book being
    crossed, or a sticky sequence gap forces adverse_risk=1 regardless of z.
    FR-26 lists exactly these three conditions -- staleness is deliberately
    NOT one of them (risk_engine.v's own gate 0x05 independently blocks any
    stale order; duplicating that here would be scope creep past what FR-26
    actually specifies).
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
