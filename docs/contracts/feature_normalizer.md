# Contract: `rtl/feature_normalizer.v`

Status: ready to hand off. Self-contained. **Can be implemented in parallel
with `docs/contracts/feature_extractor.md`** — this module's input contract
(eight raw 32-bit feature values + eight offset/shift register pairs)
doesn't require `feature_extractor.v` to exist yet, only to match its
documented output shape.

Note on scope: this module is one of S3's five listed deliverables (master
spec §15's milestone table), but its own dedicated correctness test
(`T29_saturation`, FR-22) is not itself one of S3's gating tests (T04,
T08-T12, T27) — it's listed later, alongside the ML-classifier tests
(T28-T36), which land at a future milestone. Build and unit-test it now
regardless (per this repo's bottom-up convention, and because it's small
and exact), just don't expect `T29` itself to run yet — nothing downstream
(`ml_classifier_wrap.v`, `ml_policy.v`) exists to receive its output.

## 1. Background (why this exists)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain). `feature_normalizer.v` is the master spec's `[G3]` block
(§3.1): it takes `feature_extractor.v`'s eight raw 32-bit features and maps
each one to a signed 8-bit value the (not-yet-built) hls4ml classifier
IP expects, using only power-of-two arithmetic — no multiplier, no divider,
per FR-23 (this module's data path is entirely subtract + shift + compare).

## 2. What you're building

**File:** `rtl/feature_normalizer.v`
**Testbench:** `tb/tb_feature_normalizer.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module feature_normalizer (
    input  wire         clk,
    input  wire         rst_n,   // active-low; same reset style as the
                                  // rest of this repo

    // from feature_extractor.v -- all eight, raw, un-normalized (see
    // docs/contracts/feature_extractor.md S2.2 for which are two's-
    // complement signed vs. plain unsigned; irrelevant here, see S2.2 below)
    input  wire         feat_valid,
    input  wire [1:0]   feat_slot,
    input  wire [31:0]  feat_f0_spread,
    input  wire [31:0]  feat_f1_mid_delta,
    input  wire [31:0]  feat_f2_imbalance,
    input  wire [31:0]  feat_f3_bid_chg,
    input  wire [31:0]  feat_f4_ask_chg,
    input  wire [31:0]  feat_f5_update_rate,
    input  wire [31:0]  feat_f6_last_trade_dir,
    input  wire [31:0]  feat_f7_volatility,

    // config (S9 CSR map: ML_OFFSET_0..7 @ 0x60-0x7C, ML_SHIFT_0..7 @
    // 0x80-0x9C). Direct ports, standing in for csr_block.v, which does
    // not exist yet (same pattern as symbol_filter.v's cfg_symbol_*
    // ports). Each offset/shift pair applies to the identically-numbered
    // feature (offset_0/shift_0 to F0, ... offset_7/shift_7 to F7).
    input  wire [31:0]  cfg_offset_0, input wire [31:0] cfg_shift_0,
    input  wire [31:0]  cfg_offset_1, input wire [31:0] cfg_shift_1,
    input  wire [31:0]  cfg_offset_2, input wire [31:0] cfg_shift_2,
    input  wire [31:0]  cfg_offset_3, input wire [31:0] cfg_shift_3,
    input  wire [31:0]  cfg_offset_4, input wire [31:0] cfg_shift_4,
    input  wire [31:0]  cfg_offset_5, input wire [31:0] cfg_shift_5,
    input  wire [31:0]  cfg_offset_6, input wire [31:0] cfg_shift_6,
    input  wire [31:0]  cfg_offset_7, input wire [31:0] cfg_shift_7,

    // normalized outputs -- signed 8-bit, ready for ml_classifier_wrap.v
    // (not built yet). Combinational, one cycle after feat_valid -- see S2.3.
    output reg           norm_valid,
    output reg  [1:0]    norm_slot,
    output reg  signed [7:0] x0, x1, x2, x3, x4, x5, x6, x7
);
```

(Eight pairs of scalar `cfg_offset_i`/`cfg_shift_i` ports, not a flattened
bus or an array — same reasoning as `docs/contracts/symbol_filter.md` §2.4:
Verilog-2001 has no legal 2D-array port syntax, and eight is few enough that
naming each one after its CSR register (`ML_OFFSET_0`..`ML_OFFSET_7`,
`ML_SHIFT_0`..`ML_SHIFT_7`) is clearer than a generic flattened bus.)

### 2.2 The normalization formula (FR-22) — apply identically to all eight features

```text
x_i = saturate_[-128, 127]( (raw_i - offset_i) >>> shift_i )
```

For **every** feature `i`, regardless of whether `feature_extractor.v`
treats that particular raw value as signed or unsigned pre-normalization
(`docs/contracts/feature_extractor.md` §2.2's table) — that distinction
matters to how the *raw* value was computed, not to this module. Here, all
32 bits of `raw_i` are reinterpreted as a two's-complement signed value
before the subtraction, because the subtraction result (`raw_i - offset_i`)
can legitimately go negative even for a feature that's conceptually
"unsigned" (e.g. F0/spread, if `offset_0` is configured larger than the
spread currently is) — there is nothing to special-case per feature here,
treat all eight uniformly:

1. `diff = $signed(raw_i) - $signed(offset_i)` — ordinary 32-bit
   two's-complement subtraction, then reinterpreted as a signed value
   (Verilog subtraction on `[31:0]` wires already produces the
   bit-correct two's-complement result regardless of signed/unsigned
   declaration; what actually needs the `signed` treatment is the shift in
   the next step).
2. `shifted = diff >>> shift_i[4:0]` — an **arithmetic** (sign-preserving)
   right shift by the low 5 bits of `shift_i` (0-31; this project doesn't
   define behavior for shift amounts ≥32, and none of the four `ML_WINDOW`-
   adjacent shift use cases need one — don't add handling for it).
   **This must be a true arithmetic shift, not a logical one** — see §2.4,
   this is the one detail in this whole contract most likely to be gotten
   wrong silently.
3. `x_i = saturate to signed 8-bit`: if `shifted > 127`, `x_i = 127`; if
   `shifted < -128`, `x_i = -128`; otherwise `x_i = shifted[7:0]` (the
   low 8 bits, which exactly represent `shifted` when it's already in
   range). Saturate, **never wrap** (FR-22's explicit words) — a value of
   e.g. `200` must become `127`, not silently truncate to whatever 8-bit
   pattern `200`'s low byte happens to be.

### 2.3 Timing

Combinational computation, registered output one cycle after `feat_valid` —
same convention as every prior module in this pipeline
(`docs/contracts/md_parser.md` §2.6, `docs/contracts/feature_extractor.md`
§2.5). `norm_valid` pulses for exactly one cycle, one cycle after
`feat_valid`; `norm_slot` carries `feat_slot` through unchanged, same
timing. No feature-by-feature independent latency — all eight lanes are
computed and registered together, in parallel (this module has no shared
resource between lanes to arbitrate, so there's no reason for them to ever
be at different pipeline depths).

### 2.4 Why the shift must be arithmetic, not logical — the actual Verilog footgun

Verilog's `>>>` operator only performs a true sign-extending arithmetic
shift **when both operands are declared/cast `signed`**; applied to a plain
`wire [31:0]` (unsigned by default), `>>>` silently behaves identically to
`>>` (logical shift, zero-fills from the top) — the operator alone does not
guarantee sign-preservation, the operand's signedness does. Concretely: if
`diff` represents `-500` (`32'hFFFFFE0C`) and you compute
`diff >>> 3` without `diff` being a `signed` type, you get a large positive
number (`0x1FFFFFC1`), not `-63`. The fix is to declare the intermediate
`diff` register as `reg signed [31:0]` (or apply `$signed(...)` at the
point of the shift) — then `>>>` does the correct thing. Verify this with
the explicit negative-value test vectors in §3; a testbench that only tries
positive `raw_i` values would never catch this bug.

## 3. Testbench requirements (`tb/tb_feature_normalizer.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o feature_normalizer_tb.vvp rtl/feature_normalizer.v tb/tb_feature_normalizer.v && vvp feature_normalizer_tb.vvp`),
no manual waveform inspection. Drive `feat_valid`/`feat_slot`/the eight
`feat_f*` inputs and the sixteen `cfg_offset_*`/`cfg_shift_*` config inputs
directly (no need to instantiate `feature_extractor.v`). All values below
are computed by hand, not derived by running the module and copying its
output. Cover, at minimum (apply each case to at least one feature lane;
you don't need all eight lanes exercised by every case, but every lane
should be hit by *some* case):

- **In-range, positive:** `raw=100, offset=50, shift=2` →
  `diff=50`, `50 >>> 2 = 12` (arithmetic shift of a positive number, no
  sign concern) → `x = 12`.
- **In-range, negative diff (the arithmetic-shift case, §2.4):**
  `raw=0, offset=500, shift=3` → `diff = 0 - 500 = -500`,
  `-500 >>> 3 = -63` (floor semantics: `-500/8 = -62.5`, arithmetic shift
  rounds toward negative infinity, same as Python's `>>` on a negative int
  — **not** `-62`) → `x = -63`. Get this one exactly right; it's the case
  that silently fails under a logical-shift bug.
- **Saturate high:** `raw=100000, offset=0, shift=0` → `diff=100000`,
  no shift → far above 127 → `x = 127`.
- **Saturate low:** `raw` representing `-100000` (two's complement),
  `offset=0, shift=0` → far below -128 → `x = -128`.
- **Exact boundary, no saturation:** `diff` (post-shift) exactly `127` →
  `x = 127` unchanged (not bumped down); exactly `-128` → `x = -128`
  unchanged. Confirms the saturate comparison uses `>`/`<`, not `>=`/`<=`.
- **Zero shift, zero offset:** `raw=42, offset=0, shift=0` → `x=42`,
  confirming the identity/pass-through path works when normalization is
  effectively disabled.
- **All eight lanes simultaneously, one `feat_valid` pulse:** distinct
  `raw`/`offset`/`shift` per lane, confirm all eight `x0..x7` outputs are
  correct on the same cycle, and `norm_slot` matches the input `feat_slot`.
- **`feat_valid=0`:** `norm_valid` must stay 0 that cycle (and the cycle
  after, since nothing triggered a registered update) regardless of what
  the `feat_f*` inputs are driven to.
- On any mismatch, `$display` what was expected vs. what happened (which
  lane, expected vs. actual `x_i`), then a final `$display("FAIL")` /
  `$display("PASS")` line — this project's plain self-checking-Verilog
  convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o feature_normalizer_tb.vvp rtl/feature_normalizer.v tb/tb_feature_normalizer.v` compiles with zero warnings.
- [ ] `vvp feature_normalizer_tb.vvp` prints `PASS`.
- [ ] `rtl/feature_normalizer.v` is Verilog-2001 only (no SystemVerilog).
- [ ] The negative-diff arithmetic-shift case (§3) passes with the exact
      floor-toward-negative-infinity result, not a logical-shift result —
      this is the one case most worth double-checking by hand against your
      own RTL's actual simulated output, not just trusting the code looks
      right.
- [ ] Saturation is exact at the `127`/`-128` boundaries (no off-by-one).
- [ ] No multiplier or divider anywhere in this module (FR-23) — only
      add/subtract/shift/compare.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Computing the raw F0-F7 values themselves — `feature_extractor.v`'s job
  (`docs/contracts/feature_extractor.md`).
- The classifier itself (`z = b + Σ w_i·x_i`) — `ml_classifier_wrap.v`,
  the hls4ml-generated IP, not built yet.
- Runtime CSR wiring for `cfg_offset_*`/`cfg_shift_*` — direct ports for
  now, same as every other module's `cfg_*` ports in this milestone;
  `csr_block.v` doesn't exist yet.
- Shift amounts ≥32 — undefined, not handled, not tested (§2.2).
- Any interaction with `feat_valid` arriving on consecutive cycles for
  different slots (pipelining/backpressure) — this module has no state
  that persists between two `feat_valid` pulses, so back-to-back pulses on
  different slots simply produce back-to-back independent outputs with no
  special handling needed; nothing to build or test beyond what §3 already
  covers.
