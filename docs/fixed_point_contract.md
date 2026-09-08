# Fixed-Point Contract

Every numeric format, truncation rule, and saturation boundary on the path
from raw book state to the ML verdict. Master spec §13 lists this file as a
deliverable; §5.3–§5.5 state the requirement, FR-22/FR-23/FR-27 the
constraints.

**Authority:** where this document, the RTL, and the Python golden models
disagree, the golden models win — they are written from the spec, and the RTL
is a restatement of them (master spec §11.1). This file describes what both
implement; it does not define anything on its own.

---

## 0. Universal rules

1. **No floating point anywhere** — RTL, golden model, feed generator, or
   labeler. Prices and quantities are integers counting ticks.
2. **Integer mid is `(bid + ask) >> 1`**, computed on the **full 33-bit sum**
   so the addition cannot wrap before the shift. Identical in
   `feature_extractor.v` (`midsum`/`pmsum`), `risk_engine.v` (gate `0x04`'s
   `midsum`), and `golden_model.py` (`SymbolBook.mid`).
3. **Saturate, never wrap** at every boundary that narrows a value (FR-22).
4. **Saturate exactly once** — see §3.3. A value that has been clamped must
   never re-enter an accumulator.
5. FR-23 permits **add / subtract / shift / compare only** on the feature and
   normalization stages. No multiply, no divide, no DSP.

---

## 1. Raw features — 32 bits

All eight raw features are 32 bits wide (`feature_extractor.v` outputs).
Width chosen to match §9's `ML_OFFSET_0..7` / `ML_SHIFT_0..7` registers, which
the spec already declares 32-bit — the only concrete width commitment in the
spec, so it anchors the rest rather than a narrower width being invented.

| ID | Feature | Interpretation | Domain |
| :-- | :-- | :-- | :-- |
| F0 | Spread | **unsigned** | `0 .. 2³²−1`, floors at 0 |
| F1 | Mid delta | **signed** two's-complement | `−2³¹ .. 2³¹−1` |
| F2 | Imbalance | **signed** | `−2³¹ .. 2³¹−1` |
| F3 | Bid-size change | **signed** | `−2³¹ .. 2³¹−1` |
| F4 | Ask-size change | **signed** | `−2³¹ .. 2³¹−1` |
| F5 | Update rate | **unsigned** | `0 .. WINDOW` |
| F6 | Last trade dir | **signed** | exactly `−1`, `0`, `+1` |
| F7 | Volatility | **unsigned** | `0 .. 2³²−1`, saturating |

The signed/unsigned distinction is *interpretation only*; it carries no
representation difference at this stage. The normalizer reinterprets all eight
as signed regardless (§2), which is correct because `raw − offset` can go
negative even for a conceptually-unsigned feature.

### 1.1 `sat_sub` — the shared saturating difference

Used for F2, F3, F4 and (in stage 1) F1:

```
d = $signed({1'b0, a}) - $signed({1'b0, b})    // 33-bit, cannot wrap
     d >  2³¹−1  →  0x7FFFFFFF
     d < −2³¹    →  0x80000000
     otherwise   →  d[31:0]
```

Both operands are unsigned 32-bit, so a 33-bit intermediate is sufficient by
construction — the subtraction itself never overflows, and the clamp is
applied to an exact result.

### 1.2 F0 — unsigned saturation at zero

`F0 = (ask >= bid) ? (ask - bid) : 0`. A crossed book yields 0, **not** a
sentinel. Without the guard, the unsigned subtraction would underflow to a
huge positive value and a crossed book would read as an enormous spread —
the same trap `signal_engine.v` avoids with its independent `~crossed` term
(D15).

### 1.3 `|F1|` — why the magnitude is unsigned

```
c_absf1 = c_f1[31] ? (32'd0 - c_f1) : c_f1
```

For the most-negative input `c_f1 = 0x80000000` (`−2³¹`), the negation yields
`0x80000000` again — which is exactly `+2³¹` **read as unsigned**. That is the
correct magnitude, and it is only representable because everything downstream
(`win_abs`, `f7_acc`, F7) treats this value as unsigned. `|F1| ≤ 2³¹`.

---

## 2. Normalization — 32-bit → int8

`feature_normalizer.v`, one shared code path for all eight lanes (FR-22):

```
x_i = saturate_[−128,127]( (raw_i − offset_i) >>> shift_i )
```

| Step | Rule |
| :-- | :-- |
| Reinterpret | All 32 bits of `raw` and `offset` read as two's-complement signed |
| Subtract | Ordinary 32-bit signed subtract |
| Shift | **Arithmetic** (sign-extending) right shift, by `shift_i[4:0]` |
| Saturate | `> 127 → 127`, `< −128 → −128`, else `shifted[7:0]` |

**Truncation is floor, toward negative infinity** — `−500 >>> 3 == −63`, not
`−62`. This matches Python's `>>` on a signed int exactly, which is what makes
the golden model bit-exact without a special case.

> **The `>>>` footgun.** Verilog's `>>>` only sign-extends when its left
> operand is *declared* signed. Applied to a plain `reg`, it silently degrades
> to a logical shift and every negative feature is corrupted. Both
> `feature_normalizer.v` (`norm8`) and `ml_policy.v` (`sat_risk_level`) hold
> the intermediate in an explicit `reg signed [31:0]` for this reason.

Normalization parameters are runtime CSR registers (§9 `ML_OFFSET_*` /
`ML_SHIFT_*`), not baked — resolved as §17 open question 6.

---

## 3. Accumulators and the saturate-once rule

### 3.1 Classifier — `ml_classifier_wrap.v`

| Quantity | Format | Note |
| :-- | :-- | :-- |
| Feature `x_i` | signed 8-bit | from §2 |
| Weight `w_i` | signed 8-bit | baked at synthesis via `$readmemh` |
| Product `w_i·x_i` | signed 16-bit | **exact** — `int8 × int8` always fits |
| Bias `b` | signed 32-bit | |
| Score `z` | signed 32-bit | 8 products + bias |

No saturation is applied or needed: eight products bounded by `128 × 128` plus
a 32-bit bias cannot overflow 32 bits (FR-27). The eight products are held as
explicit named intermediates rather than folded into one expression, so every
width is auditable against the spec's own table.

### 3.2 Policy telemetry — `ml_policy.v`

`risk_level = saturate_[0,255]( (z + offset) >>> shift )`, arithmetic shift by
`shift[4:0]`, clamped low to 0 and high to 255. Telemetry only; it never
affects `adverse_risk`. Thresholds `T_high`/`T_low` are signed 32-bit and
compared directly against `z`.

### 3.3 The F5/F7 window accumulator — the rule that matters most

F5 and F7 share one `WINDOW`-deep per-slot window. Since D26/D27 v2 they are
maintained **incrementally** (add the newest entry, subtract the one falling
out) rather than recomputed from scratch.

D13 originally rejected incremental accumulation for a real reason: *once a
contribution has been clamped on the way in, its original value is gone and
cannot be correctly subtracted back out later.* The incremental design is safe
only under one absolute rule:

> **Every value written into `win_abs` or `f7_acc`, and every value added to
> or subtracted from the accumulator, is the true unsaturated per-event
> magnitude. Saturation happens exactly once — producing the
> `feat_f7_volatility` output register — and that saturated value is never
> written back.**

Accumulator width:

| Quantity | Width | Derivation |
| :-- | --: | :-- |
| Per-entry `\|F1\|` | 32 bits | `≤ 2³¹` (§1.3) |
| `f7_acc` | **40 bits** | `WINDOW ≤ 32` (D13's legal set) × `2³¹` = `2³⁶`; 37 bits is exact, 40 leaves margin |
| `f5_cnt` | 6 bits | `0 .. WINDOW`, max 32 |

40 bits is sized for the parameter's **full legal range**, not the current
`WINDOW = 16` instantiation — so changing `WINDOW` to 32 needs no width
rework. It is also deliberately far below a 64-bit accumulator, whose carry
chain would have cost more depth than the adder tree the v2 patch removed.

F7's single saturation point:

```
feat_f7_volatility = (new_f7acc[39:32] != 0) ? 0xFFFFFFFF : new_f7acc[31:0]
```

**Load-bearing invariants** (true by construction, not asserted in RTL):
`f7_acc[s]` always equals the exact sum of slot `s`'s window entries, and
`f5_cnt[s]` its exact popcount. These guarantee the subtract can never
underflow — `old_abs ≤ f7_acc` and `old_upd ≤ f5_cnt` always hold. Any change
that writes a different value into either array breaks this silently.

---

## 4. Python ↔ Verilog correspondence

| Verilog | Python | Bit-exact because |
| :-- | :-- | :-- |
| `>>>` on a signed reg | `>>` on a signed int | Both floor toward −∞ |
| `sat_sub` 33-bit clamp | explicit clamp helper | Same boundaries |
| `$readmemh` weights | `_read_int8s()` reading the same `.mem` file | Same source of truth — the model reads the file the RTL loads, so a weight change cannot desynchronize them |
| `int8 × int8 → int16` | native ints | Products always fit; no truncation to reproduce |

References: `sim/feature_golden.py` (F0–F7), `sim/ml_golden.py` (classifier +
policy), `sim/golden_model.py` (book, signal, gates `0x01`–`0x08`).

---

## 5. Known edge cases and limits

Documented rather than fixed. None are reachable from the current synthetic
feed's value ranges, but each is a real divergence if the ranges widen — and
each is the same class as D15, which *was* reachable and was fixed.

1. **Normalizer subtraction can wrap.** `diff = $signed(raw) − $signed(offset)`
   is a plain 32-bit subtract. Python computes it unbounded. For an extreme
   configured `offset` (near ±2³¹) against an extreme raw feature, the RTL
   wraps and the model does not.
2. **`risk_level`'s addition can wrap.** `(z + $signed(offset))` in
   `sat_risk_level` is a 32-bit add with the same property. Telemetry only —
   it cannot affect `adverse_risk` or any order.
3. **Shift amounts ≥ 32 are undefined.** The RTL uses only the low 5 bits
   (`shift[4:0]`); Python uses the full value. Master spec §5.5 does not bound
   `ML_SHIFT_*`, so a CSR write of ≥ 32 diverges. Legal values are 0–31.
4. **`cfg_ml_window` (CSR `0x5C`) has no RTL consumer.** `WINDOW` is an
   elaboration-time parameter (D13), so the register exists in the map but
   does not change behaviour. FR-32 lists `W` as runtime-configurable; that is
   unmet, deliberately (D24 item 3).

---

## 6. What is *not* fixed-point contract

- **Prices and quantities** are exact 32-bit integers end to end. They are
  never normalized, shifted, or quantized — only compared and subtracted. The
  int8 domain begins at the normalizer and is confined to the ML branch.
- **The risk engine** does no fixed-point arithmetic. Its 33-bit signed
  intermediates (position, price band) exist to prevent overflow on exact
  integers, not to represent fractions. Position is stored 32-bit signed and
  **sign-extended** when read back — zero-extension would break every gate
  after the first short sale.
