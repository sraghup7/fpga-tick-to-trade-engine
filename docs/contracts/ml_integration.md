# Contract: S6 ML integration — fallback linear classifier

Status: ready to hand off, **after** `docs/contracts/feature_extractor_patch.md`
has landed and been verified (it has — commit `dadde20`). This is the main
S6 milestone contract: three new modules, one new golden model, and the
`tob_top.v` wiring that finally exercises the ML branch end to end.

## 1. Background

### 1.1 Why a fallback, not the real hls4ml IP

S4 (`model/`, `hls4ml/`) has not started — `model/` has only a `README.md`,
`hls4ml/` doesn't exist. Master spec §15 has a standing fallback for
exactly this: *"the classifier is architecturally isolated behind
`ml_classifier_wrap.v`. A hand-written `linear_classifier.v` (8 MACs, ~50
lines) can stand in for the hls4ml IP with zero change to the rest of the
design... Ship the hand-written version if necessary; add the hls4ml IP as
soon as it builds."* This contract builds S6 against that fallback so the
datapath and risk gate `0x09` are fully closed out in simulation without
waiting on the ML collaborator — the same "build ahead of the ML-owned
milestone" pattern already used for S5 (`signal_engine.v`).

**The weights are not trained — they are a documented placeholder**
(`model/weights.mem`/`model/bias.mem`, §3.3). When S4 eventually produces
real trained weights, only those two files change; no RTL or wiring in
this contract changes. State this plainly in any code comment or doc that
touches it — consistent with this project's standing rule to never imply
the classifier is predictive of real adverse selection.

### 1.2 What already exists — read this before writing anything

Independent verification while researching this contract turned up more
already-built plumbing than expected. **Do not re-add any of this:**

- `csr_block.v` already has the **entire** ML register map wired
  end-to-end internally: `cfg_ml_th_high`/`cfg_ml_th_low` (`0x48`/`0x4C`),
  `cfg_ml_action`/`cfg_ml_reduce_shift` (already connected to
  `risk_engine.v`), `cfg_ml_score_offset`/`cfg_ml_score_shift`
  (`0x54`/`0x58`), `cfg_ml_window` (`0x5C`, see §7.4 for why it has no
  consumer), `cfg_offset_0..7`/`cfg_shift_0..7` (`0x60`–`0x9C`), and the
  `ml_event_valid`/`ml_adverse_pulse`/`ml_benign_pulse`/
  `ml_safe_forced_pulse` counter-pulse inputs feeding `cnt_ml_events`/
  `cnt_ml_adverse`/`cnt_ml_benign`/`cnt_ml_safe_forced` and `STATUS` bit 4.
  All of it is simply tied off (`()`) in `tob_top.v` today — this
  contract's `tob_top.v` work is pure wiring, no `csr_block.v` patch
  needed.
- `tob_engine.v` already exposes both the registered `bid_valid`/
  `ask_valid`/`crossed` buses (`NUM_SYMBOLS`-wide) and the D23 `next_*`
  scalars — both used below, for different consumers (§3.2).
- `feature_extractor.v` (patched, `dadde20`) and `feature_normalizer.v`
  are fully built and tested; neither is instantiated in `tob_top.v` yet.
  `feature_normalizer.v`'s `cfg_offset_0..7`/`cfg_shift_0..7` ports are
  exactly `csr_block.v`'s `cfg_offset_0..7`/`cfg_shift_0..7` outputs —
  direct 1:1 wiring, no adapter needed.
- `risk_engine.v`'s gate `0x09` is fully built (`gate_ml_fired_c =
  adverse_risk & ~cfg_ml_action`, the reduce-path arithmetic, the reject-
  reason priority) — it just reads `adverse_risk` tied to `1'b0`. This
  contract's only `risk_engine.v`-facing change is retargeting that one
  connection.

### 1.3 Pipeline timing and `ALIGN_DEPTH`

Every stage in this codebase registers its output exactly one cycle after
its trigger input (established by `feature_extractor.v`/
`feature_normalizer.v`, continued here). Counting cycles from
`book_upd_valid` (cycle 0):

| Stage | Valid-readable at |
| :-- | --: |
| `feature_extractor.v` (`feat_valid`) | +1 |
| `feature_normalizer.v` (`norm_valid`) | +2 |
| `ml_classifier_wrap.v` (`ml_valid`) | +3 |
| `ml_policy.v` (registered `adverse_risk` reflects this event) | +4 |
| `signal_engine.v` (`sig_valid`) | +1 |

`ALIGN_DEPTH = (ML branch, 4) − (signal branch, 1) = 3` — a fixed-depth
delay line (§2) delays `signal_engine.v`'s order-intent bus by exactly 3
cycles so it reaches `risk_engine.v` on the same cycle `adverse_risk`'s
registered value reflects the *same* triggering event. This is shallower
than the master spec's own estimate of "4–5 cycles" (§7.1) because that
estimate assumed the real hls4ml IP's 2–3 cycle classifier latency; the
hand-written 8-MAC classifier here is small enough to close timing in one
combinational cycle, registered once. **`ALIGN_DEPTH` is a single
`localparam` in `tob_top.v`** — when the real hls4ml IP eventually
replaces `ml_classifier_wrap.v`'s internals, only that one constant may
need to change, nothing else.

Why this is safe under back-to-back messages (NFR-5, one message/cycle):
each pipeline stage advances exactly one event per cycle in strict
program order, so the delay line's output for event N always lands
exactly when `adverse_risk`'s registered value has just been updated *by
event N* — never a race with event N+1, which is always exactly one cycle
further behind at every stage. This is the same reasoning already applied
to `risk_engine.v`'s existing reads of the registered `bid_price`/
`ask_price`/`crossed` bus (`docs/contracts/tob_engine_signal_patch.md`
§1.3) — reading a registered bus safely, one or more cycles after the
triggering write, is a precedented, accepted pattern in this codebase, not
new here.

### 1.4 Scope decisions (record as D24 in `docs/design_decisions.md` when
this lands — not part of this contract to write, but flag it for the
commit)

- **Fail-safe forcing (FR-26/FR-31) is implemented for invalid side /
  crossed book / sequence gap, but NOT for per-event staleness.**
  `risk_engine.v`'s own gate `0x05` already independently blocks any order
  built from a stale message outright, regardless of the ML verdict — so
  the safety property "no order emitted from stale state" already holds
  without this. The gap this leaves: a stale event's (possibly
  meaningless) `z` could still update the *persisting* hysteresis state
  that carries forward into the *next*, fresh event. Implementing full
  per-event staleness forcing in `ml_policy.v` would require duplicating
  `risk_engine.v`'s `pend_prev_cycle`/`pend_msg_cycle` timestamp mechanism
  per-slot for every book event (today it only runs for events that also
  produce a `signal_engine.v` intent) — real work, deliberately deferred.
  Flagged, not silently dropped.
- **`score_raw`/`risk_level` (FR-33) are produced by `ml_policy.v` but not
  wired anywhere in `tob_top.v`** — no existing consumer (no CSR readback
  register, no diagnostic-frame mechanism) exists yet for either. Leave
  `tob_top.v`'s connections to them as `()`.
- **`cfg_ml_window` (CSR `0x5C`) has no RTL consumer and this contract
  does not give it one.** `feature_extractor.v`'s window depth is the
  elaboration-time `WINDOW` parameter (D13), not a runtime signal — this
  mismatch between the CSR register's existence and its (lack of) effect
  predates this contract and is not introduced or fixed here.

## 2. New module: `rtl/common/delay_line.v`

A generic, reusable N-cycle valid+data delay — the alignment register from
§1.3, built as a `rtl/common/` utility (matching `counter_sat.v`/
`sync_2ff.v` precedent) rather than inlined in `tob_top.v`.

```verilog
module delay_line #(
    parameter integer WIDTH = 1,
    parameter integer DEPTH = 1   // >= 1; DEPTH=0 not supported
) (
    input  wire             clk,
    input  wire             rst_n,   // active-low, async-assert/sync-deassert
    input  wire             in_valid,
    input  wire [WIDTH-1:0] in_data,
    output wire             out_valid,
    output wire [WIDTH-1:0] out_data
);
```

Behavior: a `DEPTH`-stage shift register of `{valid, data}` pairs.
`out_valid`/`out_data` reflect whatever was presented at `in_valid`/
`in_data` exactly `DEPTH` cycles earlier. On `!rst_n`, every stage's
`valid` clears to `0` (data don't-care) so no stale garbage can leak out
of reset. Use an unpacked `reg` array indexed by a `for`-loop `integer`
(compile-time-bounded, `DEPTH` fixed at elaboration) — matches this
codebase's existing precedent for BRAM-shaped/array state (e.g.
`latency_histogram.v`'s bucket array), not a runtime-indexed structure.

### 2.1 `tb/tb_delay_line.v`

Directed cases: `DEPTH=1` passes a single value through with exactly one
cycle of delay; `DEPTH=3` (the value this contract actually uses) — drive
a distinct value each cycle for at least 6 cycles, confirm `out_data`/
`out_valid` at cycle `N` matches `in_data`/`in_valid` from cycle `N-3`
exactly; a gap (one cycle of `in_valid=0` between two `in_valid=1` cycles)
correctly produces a gap in `out_valid` three cycles later, not a
collapsed/merged pulse; reset mid-stream clears the whole pipeline (three
cycles of `out_valid=0` follow, even if `in_valid` is driven high through
reset). `$display("PASS")`/`$display("FAIL")` per this project's
convention.

## 3. New module: `rtl/ml_classifier_wrap.v`

The fallback classifier itself — hand-written, not hls4ml-generated, per
§1.1. Implements FR-27 exactly per master spec §5.4's parameter-format
table: `int8` features/weights, `int16` exact products, `int32`
accumulator.

```verilog
module ml_classifier_wrap #(
    parameter WEIGHTS_FILE = "model/weights.mem",
    parameter BIAS_FILE    = "model/bias.mem"
) (
    input  wire        clk,
    input  wire        rst_n,

    // from feature_normalizer.v
    input  wire         norm_valid,
    input  wire [1:0]   norm_slot,
    input  wire signed [7:0] x0, x1, x2, x3, x4, x5, x6, x7,

    // to ml_policy.v -- registered one cycle after norm_valid
    output reg          ml_valid,
    output reg  [1:0]   ml_slot,
    output reg  signed [31:0] z
);
```

### 3.1 Weight/bias loading

```verilog
reg signed [7:0]  w_mem    [0:7];
reg signed [31:0] bias_mem [0:0];
initial begin
    $readmemh(WEIGHTS_FILE, w_mem);
    $readmemh(BIAS_FILE, bias_mem);
end
wire signed [31:0] bias = bias_mem[0];
```

Weights and bias are elaboration-time-loaded, not CSR-writable — matches
master spec §9's explicit note that weights are "baked in at synthesis,"
same hardware contract the real hls4ml IP will have. Swapping in trained
weights later means replacing these two `.mem` files only.

### 3.2 The accumulation, exactly per §5.4's width contract

```verilog
wire signed [15:0] p0 = $signed(x0) * $signed(w_mem[0]);
wire signed [15:0] p1 = $signed(x1) * $signed(w_mem[1]);
wire signed [15:0] p2 = $signed(x2) * $signed(w_mem[2]);
wire signed [15:0] p3 = $signed(x3) * $signed(w_mem[3]);
wire signed [15:0] p4 = $signed(x4) * $signed(w_mem[4]);
wire signed [15:0] p5 = $signed(x5) * $signed(w_mem[5]);
wire signed [15:0] p6 = $signed(x6) * $signed(w_mem[6]);
wire signed [15:0] p7 = $signed(x7) * $signed(w_mem[7]);

wire signed [31:0] z_c = bias
    + $signed(p0) + $signed(p1) + $signed(p2) + $signed(p3)
    + $signed(p4) + $signed(p5) + $signed(p6) + $signed(p7);
```

Explicit 16-bit product intermediates (not folded into one wide
expression) — deliberate, matches §5.4's table literally and keeps every
intermediate width auditable, in the same spirit as this codebase's
established care around signed-arithmetic widths (`risk_engine.v`'s D16/
FR-45 comments, `feature_normalizer.v`'s `>>>` footgun note).

### 3.3 `model/weights.mem`, `model/bias.mem`, `model/model_config.json`

**Not trained — an explicit, documented placeholder.** Equal weight on
every feature, zero bias: `z = Σ x_i`. Chosen for this reason only: it is
trivially hand-computable for every test vector in this contract and in
`sim/ml_golden.py`'s regression, so every expected value below can be
(and was) verified by hand, not just trusted from a tool.

`model/weights.mem` (8 lines, `$readmemh` format, one `int8` per line,
matching `w_mem[0]`.. `w_mem[7]` in order F0..F7):

```text
01
01
01
01
01
01
01
01
```

`model/bias.mem` (1 line, 32-bit hex):

```text
00000000
```

`model/model_config.json` — machine-readable record of this placeholder,
per master spec §5.5's "part of the model's hardware contract" framing:

```json
{
  "status": "PLACEHOLDER - not trained. S4 has not run. This is the
    master spec Section 15 fallback classifier, wired in for S6 so the
    datapath and risk gate 0x09 close out in simulation without blocking
    on the ML collaborator. Replace weights.mem/bias.mem with S4's
    trained, quantized output when available -- no RTL or wiring change
    required elsewhere.",
  "features": ["F0_spread", "F1_mid_delta", "F2_imbalance", "F3_bid_chg",
               "F4_ask_chg", "F5_update_rate", "F6_last_trade_dir",
               "F7_volatility"],
  "weights": [1, 1, 1, 1, 1, 1, 1, 1],
  "bias": 0,
  "formula": "z = bias + sum(w_i * x_i), int8 features/weights, int16 exact products, int32 accumulator"
}
```

(Write this as valid JSON — the multi-line `status` string above is
prose for this contract; collapse it to one JSON string in the actual
file.)

### 3.4 `tb/tb_ml_classifier_wrap.v`

Using the exact placeholder weights above (`w_i=1` for all `i`, `b=0`, so
`z = Σx_i` — every case below is hand-checkable by simple addition):

- **All-zero features:** `x0..x7 = 0` → `z = 0`.
- **All-max-positive:** `x0..x7 = 127` → `z = 8 × 127 = 1016`.
- **All-max-negative:** `x0..x7 = -128` → `z = 8 × (−128) = −1024`.
- **Mixed signs, hand-computed:** e.g. `x = {10, -20, 30, -40, 50, -60,
  70, -80}` → `z = 10−20+30−40+50−60+70−80 = −40`.
- **Timing:** `ml_valid`/`ml_slot`/`z` register exactly one cycle after
  `norm_valid`; `norm_slot` passes through unchanged; a `norm_valid=0`
  cycle produces no `ml_valid` pulse.
- **Back-to-back `norm_valid` pulses** (two different feature vectors on
  consecutive cycles): confirm both are correctly pipelined, no vector
  overwritten or dropped.

## 4. New module: `rtl/ml_policy.v`

Hysteresis (FR-28/29), partial fail-safe forcing (FR-26/31, §1.4), and
telemetry pulse generation (FR-33, feeding `csr_block.v`'s existing
counter inputs).

```verilog
module ml_policy #(
    parameter integer NUM_SYMBOLS = 4   // matches every other S3/S5/S6 module
) (
    input  wire        clk,
    input  wire        rst_n,

    // from ml_classifier_wrap.v
    input  wire         ml_valid,
    input  wire [1:0]   ml_slot,
    input  wire signed [31:0] z,

    // fail-safe inputs -- tob_engine.v's REGISTERED buses (§1.3: safe to
    // read here, this cycle is well past the triggering event's register
    // commit) and seq_monitor.v's feed-wide sticky bit
    input  wire [NUM_SYMBOLS-1:0] bid_valid,
    input  wire [NUM_SYMBOLS-1:0] ask_valid,
    input  wire [NUM_SYMBOLS-1:0] crossed,
    input  wire                    seq_gap,

    // config (S9 CSR map), direct ports from csr_block.v
    input  wire signed [31:0] cfg_ml_th_high,   // 0x48
    input  wire signed [31:0] cfg_ml_th_low,    // 0x4C
    input  wire [31:0] cfg_ml_score_offset,     // 0x54
    input  wire [31:0] cfg_ml_score_shift,      // 0x58

    // to risk_engine.v -- persisting hysteresis level, valid every cycle
    output reg          adverse_risk,

    // telemetry (FR-33) -- no consumer wired yet (§1.4), reserved
    output reg  signed [31:0] score_raw,
    output reg  [7:0]         risk_level,

    // to csr_block.v -- one-cycle pulses per ML event
    output reg          ml_event_valid,
    output reg          ml_adverse_pulse,
    output reg          ml_benign_pulse,
    output reg          ml_safe_forced_pulse
);
```

### 4.1 Fail-safe condition

```verilog
wire safe_state_c = ~bid_valid[ml_slot] | ~ask_valid[ml_slot]
                   | crossed[ml_slot] | seq_gap;
```

### 4.2 `risk_level` (FR-33), exactly per §5.4: `saturate((z + offset) >> shift)`

```verilog
function [7:0] sat_risk_level;
    input signed [31:0] zin;
    input [31:0] offset;
    input [31:0] shift;
    reg signed [31:0] shifted;
    begin
        shifted = (zin + $signed(offset)) >>> shift[4:0];   // true arithmetic
                                                              // shift (feature_
                                                              // normalizer.v's
                                                              // >>> footgun note
                                                              // applies here too)
        if (shifted > 32'sd255)      sat_risk_level = 8'd255;
        else if (shifted < 32'sd0)   sat_risk_level = 8'd0;
        else                          sat_risk_level = shifted[7:0];
    end
endfunction
```

### 4.3 Hysteresis + telemetry, registered on `ml_valid`

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        adverse_risk          <= 1'b0;   // see note below -- reset value is
                                          // never actually read before the
                                          // first real ml_valid update lands
        score_raw              <= 32'sd0;
        risk_level              <= 8'd0;
        ml_event_valid          <= 1'b0;
        ml_adverse_pulse        <= 1'b0;
        ml_benign_pulse          <= 1'b0;
        ml_safe_forced_pulse    <= 1'b0;
    end else if (ml_valid) begin
        ml_event_valid <= 1'b1;
        score_raw       <= z;
        risk_level       <= sat_risk_level(z, cfg_ml_score_offset, cfg_ml_score_shift);
        if (safe_state_c) begin
            adverse_risk           <= 1'b1;
            ml_safe_forced_pulse   <= 1'b1;
            ml_adverse_pulse       <= 1'b1;
            ml_benign_pulse         <= 1'b0;
        end else if (z >= cfg_ml_th_high) begin
            adverse_risk           <= 1'b1;
            ml_adverse_pulse       <= 1'b1;
            ml_benign_pulse         <= 1'b0;
            ml_safe_forced_pulse   <= 1'b0;
        end else if (z <= cfg_ml_th_low) begin
            adverse_risk           <= 1'b0;
            ml_adverse_pulse       <= 1'b0;
            ml_benign_pulse         <= 1'b1;
            ml_safe_forced_pulse   <= 1'b0;
        end else begin
            // hysteresis hold: adverse_risk keeps its current value:
            adverse_risk           <= adverse_risk;
            ml_adverse_pulse       <= adverse_risk;   // still counts toward
            ml_benign_pulse         <= ~adverse_risk;  // exactly one bucket
            ml_safe_forced_pulse   <= 1'b0;
        end
    end else begin
        ml_event_valid          <= 1'b0;
        ml_adverse_pulse        <= 1'b0;
        ml_benign_pulse          <= 1'b0;
        ml_safe_forced_pulse    <= 1'b0;
        // adverse_risk/score_raw/risk_level hold their last value
    end
end
```

The hold-zone branch (`T_low < z < T_high`) still asserts exactly one of
`ml_adverse_pulse`/`ml_benign_pulse` (based on the *current*, held
`adverse_risk`), so `cnt_ml_events = cnt_ml_adverse + cnt_ml_benign`
(§10's invariant) holds on every event, not just threshold-crossing ones.
`safe_state_c` always forces both `ml_safe_forced_pulse` and
`ml_adverse_pulse`, satisfying `cnt_ml_safe_forced ≤ cnt_ml_adverse` by
construction.

### 4.4 `tb/tb_ml_policy.v`

- **Rising through `T_high`:** `cfg_ml_th_high=20`, `cfg_ml_th_low=-20`.
  Drive `ml_valid` with `z=25` (safe_state_c=0) → `adverse_risk=1` after
  the register edge, `ml_adverse_pulse=1`, `ml_benign_pulse=0`.
- **Falling through `T_low`:** continuing from adverse, drive `z=-25` →
  `adverse_risk=0`, `ml_benign_pulse=1`.
- **Hold zone:** from a known `adverse_risk` state, drive `z=0` (strictly
  between −20 and 20) → `adverse_risk` unchanged from its prior value,
  and the correct one of `ml_adverse_pulse`/`ml_benign_pulse` still fires
  matching whichever state was held.
- **Fail-safe forcing overrides a benign `z`:** `z=-25` (would clear
  benign) but `crossed[ml_slot]=1` → `adverse_risk` forced to `1`,
  `ml_safe_forced_pulse=1` and `ml_adverse_pulse=1` together, regardless
  of `z`. Repeat for `~bid_valid[ml_slot]`, `~ask_valid[ml_slot]`, and
  `seq_gap=1` individually — each alone must force it.
- **`risk_level` saturation:** `cfg_ml_score_offset=0`, `cfg_ml_score_shift=0`,
  `z=300` → `risk_level=255` (saturates, doesn't wrap to `44`). `z=-50` →
  `risk_level=0`. A mid-range in-bounds case with a nonzero shift, e.g.
  `z=100`, `offset=0`, `shift=2` → `(100>>>2)=25` → `risk_level=25`.
- **`ml_slot` indexing:** confirm fail-safe forcing reads `bid_valid`/
  `ask_valid`/`crossed` at `ml_slot`, not slot 0 unconditionally — drive
  distinct valid/crossed patterns per slot and confirm only the addressed
  slot's condition matters.
- **No `ml_valid`:** every output holds; no pulse asserted.

## 5. `sim/ml_golden.py` — bit-exact Python reference

New file (S1's original scope for this file was never done — S4 hasn't
run). Mirrors `sim/feature_golden.py`'s style (a class holding persistent
state, called once per feature vector). Match this shape:

```python
class MLClassifier:
    """Bit-exact reference for ml_classifier_wrap.v + ml_policy.v (S6
    fallback). Weights/bias loaded from model/weights.mem, model/bias.mem
    -- the same placeholder files the RTL loads via $readmemh, so this
    stays bit-exact even if the placeholder values ever change."""

    def __init__(self, th_high: int, th_low: int,
                 score_offset: int = 0, score_shift: int = 0,
                 weights_path: str = "model/weights.mem",
                 bias_path: str = "model/bias.mem"):
        ...  # load 8 int8 weights + int32 bias from the .mem files
        self.adverse_risk = 0   # persisting hysteresis state, reset default

    def classify(self, features: tuple[int, ...],   # 8 signed int8 values,
                                                       # F0..F7 order
                 bid_valid: bool, ask_valid: bool,
                 crossed: bool, seq_gap: bool) -> "MLResult":
        """One classifier event. Updates self.adverse_risk in place
        (hysteresis persists across calls, matching ml_policy.v's
        registered state) and returns the full verdict for this event."""
        ...
```

`MLResult` (a small dataclass or namedtuple): `z: int`, `risk_level: int`,
`adverse_risk: int`, `safe_forced: bool`. Formulas exactly as §3.2/§4.1–
§4.2 specify: `z = bias + sum(w_i * x_i)` (plain Python ints, no
saturation needed at these magnitudes — max `|z|` is 1024, per §3.4);
`risk_level = clamp((z + score_offset) >> score_shift, 0, 255)`, using
Python's native floor-toward-negative-infinity `>>` on a signed int
(matches the RTL's `>>>` sign-extending arithmetic shift, same
correspondence `feature_golden.py`/`feature_normalizer.v` already rely
on); hysteresis and fail-safe forcing exactly as §4.3's `always` block,
transcribed to Python control flow.

### 5.1 `sim/test_ml_golden_handcase.py`

A hand-computed regression, run via `scripts/run_sim.sh` (§8), same
pattern as `sim/test_feature_golden_handcase.py`: construct an
`MLClassifier` with `th_high=20, th_low=-20`, feed it the same four
feature vectors as §3.4's testbench cases plus one hold-zone and one
fail-safe case, assert every returned field matches hand-computed
values (the same numbers already hand-verified in §3.4/§4.4 above — reuse
them, don't invent new ones, so this file and the two Verilog testbenches
are cross-checking the *same* worked examples).

## 6. New cross-module regression: `tb/tb_ml_chain.v`

The full ML branch, real modules chained end to end: `tob_engine.v` →
`feature_extractor.v` → `feature_normalizer.v` → `ml_classifier_wrap.v` →
`ml_policy.v` (no `tob_top.v`). Mirrors `tb_signal_tob_chain.v`/
`tb_feature_tob_chain.v` in spirit: drive message-shaped stimulus into
`tob_engine.v`'s own inputs, feed `feature_normalizer.v`'s
`cfg_offset_i`/`cfg_shift_i` all zero (identity normalization — raw
feature values pass through, clamped to `int8` range, so expected `z`
values are hand-computable directly from the raw F0–F7 formulas without
also re-deriving the normalization step), drive `cfg_ml_th_high`/
`cfg_ml_th_low` to fixed test values, and check the final `adverse_risk`/
`ml_event_valid`/`z` against `sim/ml_golden.py`'s `MLClassifier`
(construct one in a comment/companion note, or simply hand-transcribe its
verdict for the exact stimulus used — either way, the expected values in
this file's `check` calls must match what `MLClassifier` would produce for
the same inputs).

Cover: a QUOTE sequence producing a `z` past `T_high` (confirm
`adverse_risk` asserts on the correct aligned cycle — `feat_valid`+1+1 =
book_upd_valid+3, i.e. `ml_valid`'s own cycle, since this chain doesn't
include the alignment delay line or `risk_engine.v`); a book-invalidating
CLEAR forcing fail-safe adverse (§4.1); multi-symbol independence
(`NUM_SYMBOLS=4`, confirms `ml_slot` indexing end to end through all four
new/patched modules together). `$display("PASS")`/`$display("FAIL")` per
convention.

## 7. `tob_top.v` wiring

### 7.1 New wire declarations

Add after `u_sig`'s instantiation (after the existing `sig_valid`/
`sig_slot`/`sig_side`/`sig_price`/`sig_qty`/`err_signal_conflict`/
`cfg_min_spread`/`cfg_imb_shift`/`cfg_order_qty` block, i.e. after line
399's declarations and before the `signal_engine u_sig (` instantiation,
or immediately after it — either position is fine, keep the ML branch's
declarations grouped together):

```verilog
// ---- ML branch (S6) ----
wire         feat_valid;
wire [1:0]   feat_slot;
wire [31:0]  feat_f0_spread, feat_f1_mid_delta, feat_f2_imbalance;
wire [31:0]  feat_f3_bid_chg, feat_f4_ask_chg, feat_f5_update_rate;
wire [31:0]  feat_f6_last_trade_dir, feat_f7_volatility;

wire         norm_valid;
wire [1:0]   norm_slot;
wire signed [7:0] norm_x0, norm_x1, norm_x2, norm_x3;
wire signed [7:0] norm_x4, norm_x5, norm_x6, norm_x7;

wire         ml_valid;
wire [1:0]   ml_slot;
wire signed [31:0] ml_z;

wire         adverse_risk;

wire [31:0] cfg_offset_0, cfg_shift_0, cfg_offset_1, cfg_shift_1;
wire [31:0] cfg_offset_2, cfg_shift_2, cfg_offset_3, cfg_shift_3;
wire [31:0] cfg_offset_4, cfg_shift_4, cfg_offset_5, cfg_shift_5;
wire [31:0] cfg_offset_6, cfg_shift_6, cfg_offset_7, cfg_shift_7;
wire signed [31:0] cfg_ml_th_high, cfg_ml_th_low;
wire [31:0] cfg_ml_score_offset, cfg_ml_score_shift;

// ---- signal-branch alignment (S6): delays sig_valid/sig_slot/sig_side/
// sig_price/sig_qty by ALIGN_DEPTH cycles so they reach u_risk on the
// same cycle adverse_risk's registered value reflects the SAME
// triggering event (docs/contracts/ml_integration.md S1.3). u_csr's own
// sig_valid/sig_side connections below stay on the RAW (unaligned)
// u_sig outputs -- they count signals as generated, not as risk-gated.
localparam ALIGN_DEPTH = 3;
wire        sig_valid_aligned;
wire [73:0] sig_data_aligned;
wire [1:0]  sig_slot_aligned  = sig_data_aligned[73:72];
wire [7:0]  sig_side_aligned  = sig_data_aligned[71:64];
wire [31:0] sig_price_aligned = sig_data_aligned[63:32];
wire [31:0] sig_qty_aligned   = sig_data_aligned[31:0];

wire        ml_event_valid, ml_adverse_pulse, ml_benign_pulse, ml_safe_forced_pulse;
```

### 7.2 New instantiations

Place after `u_sig`'s instantiation, before the `wire [31:0]
cfg_max_order_qty;` block that precedes `u_risk`:

```verilog
feature_extractor #(
    .NUM_SYMBOLS (4),
    .WINDOW      (16)
) u_feat (
    .clk                    (gmii_rx_clk),
    .rst_n                  (engine_rst_n),
    .msg_type               (md_msg_type),
    .msg_side               (md_msg_side),
    .msg_applied            (msg_applied),
    .book_upd_valid         (book_upd_valid),
    .applied_slot           (applied_slot),
    .next_bid_price         (next_bid_price),
    .next_bid_qty           (next_bid_qty),
    .next_ask_price         (next_ask_price),
    .next_ask_qty           (next_ask_qty),
    .feat_valid             (feat_valid),
    .feat_slot              (feat_slot),
    .feat_f0_spread         (feat_f0_spread),
    .feat_f1_mid_delta      (feat_f1_mid_delta),
    .feat_f2_imbalance      (feat_f2_imbalance),
    .feat_f3_bid_chg        (feat_f3_bid_chg),
    .feat_f4_ask_chg        (feat_f4_ask_chg),
    .feat_f5_update_rate    (feat_f5_update_rate),
    .feat_f6_last_trade_dir (feat_f6_last_trade_dir),
    .feat_f7_volatility     (feat_f7_volatility)
);

feature_normalizer u_norm (
    .clk                (gmii_rx_clk),
    .rst_n              (engine_rst_n),
    .feat_valid         (feat_valid),
    .feat_slot          (feat_slot),
    .feat_f0_spread         (feat_f0_spread),
    .feat_f1_mid_delta      (feat_f1_mid_delta),
    .feat_f2_imbalance      (feat_f2_imbalance),
    .feat_f3_bid_chg        (feat_f3_bid_chg),
    .feat_f4_ask_chg        (feat_f4_ask_chg),
    .feat_f5_update_rate    (feat_f5_update_rate),
    .feat_f6_last_trade_dir (feat_f6_last_trade_dir),
    .feat_f7_volatility     (feat_f7_volatility),
    .cfg_offset_0 (cfg_offset_0), .cfg_shift_0 (cfg_shift_0),
    .cfg_offset_1 (cfg_offset_1), .cfg_shift_1 (cfg_shift_1),
    .cfg_offset_2 (cfg_offset_2), .cfg_shift_2 (cfg_shift_2),
    .cfg_offset_3 (cfg_offset_3), .cfg_shift_3 (cfg_shift_3),
    .cfg_offset_4 (cfg_offset_4), .cfg_shift_4 (cfg_shift_4),
    .cfg_offset_5 (cfg_offset_5), .cfg_shift_5 (cfg_shift_5),
    .cfg_offset_6 (cfg_offset_6), .cfg_shift_6 (cfg_shift_6),
    .cfg_offset_7 (cfg_offset_7), .cfg_shift_7 (cfg_shift_7),
    .norm_valid  (norm_valid),
    .norm_slot   (norm_slot),
    .x0 (norm_x0), .x1 (norm_x1), .x2 (norm_x2), .x3 (norm_x3),
    .x4 (norm_x4), .x5 (norm_x5), .x6 (norm_x6), .x7 (norm_x7)
);

ml_classifier_wrap u_ml (
    .clk        (gmii_rx_clk),
    .rst_n      (engine_rst_n),
    .norm_valid (norm_valid),
    .norm_slot  (norm_slot),
    .x0 (norm_x0), .x1 (norm_x1), .x2 (norm_x2), .x3 (norm_x3),
    .x4 (norm_x4), .x5 (norm_x5), .x6 (norm_x6), .x7 (norm_x7),
    .ml_valid   (ml_valid),
    .ml_slot    (ml_slot),
    .z          (ml_z)
);

ml_policy u_policy (
    .clk                  (gmii_rx_clk),
    .rst_n                (engine_rst_n),
    .ml_valid             (ml_valid),
    .ml_slot              (ml_slot),
    .z                    (ml_z),
    .bid_valid            (bid_valid),
    .ask_valid            (ask_valid),
    .crossed              (crossed),
    .seq_gap              (seq_gap),
    .cfg_ml_th_high       (cfg_ml_th_high),
    .cfg_ml_th_low        (cfg_ml_th_low),
    .cfg_ml_score_offset  (cfg_ml_score_offset),
    .cfg_ml_score_shift   (cfg_ml_score_shift),
    .adverse_risk         (adverse_risk),
    .score_raw            (),
    .risk_level           (),
    .ml_event_valid       (ml_event_valid),
    .ml_adverse_pulse     (ml_adverse_pulse),
    .ml_benign_pulse      (ml_benign_pulse),
    .ml_safe_forced_pulse (ml_safe_forced_pulse)
);

delay_line #(
    .WIDTH (74),   // sig_slot(2) + sig_side(8) + sig_price(32) + sig_qty(32)
    .DEPTH (ALIGN_DEPTH)
) u_align (
    .clk       (gmii_rx_clk),
    .rst_n     (engine_rst_n),
    .in_valid  (sig_valid),
    .in_data   ({sig_slot, sig_side, sig_price, sig_qty}),
    .out_valid (sig_valid_aligned),
    .out_data  (sig_data_aligned)
);
```

### 7.3 Changes to existing lines

In `u_risk`'s instantiation:

```verilog
// old:
.sig_valid              (sig_valid),
.sig_slot               (sig_slot),
.sig_side               (sig_side),
.sig_price               (sig_price),
.sig_qty                 (sig_qty),
...
.adverse_risk            (1'b0),   // no ML path yet (S1.3/D22)

// new:
.sig_valid              (sig_valid_aligned),
.sig_slot               (sig_slot_aligned),
.sig_side               (sig_side_aligned),
.sig_price               (sig_price_aligned),
.sig_qty                 (sig_qty_aligned),
...
.adverse_risk            (adverse_risk),
```

`u_risk`'s `.msg_applied`/`.applied_slot`/`.bid_price`/`.ask_price`/
`.crossed` connections are **unchanged** — those come from `tob_engine.v`
directly, already correctly timed per D23 §1.3, nothing to do with the
signal-branch alignment.

In `u_csr`'s instantiation (its `.sig_valid(sig_valid)`/
`.sig_side(sig_side)` stay exactly as they are — raw, unaligned, do not
touch):

```verilog
// old:
.cfg_ml_th_high         (),
.cfg_ml_th_low          (),
.cfg_ml_score_offset    (),
.cfg_ml_score_shift     (),
.cfg_ml_window          (),
.cfg_offset_0           (), .cfg_shift_0 (),
.cfg_offset_1           (), .cfg_shift_1 (),
.cfg_offset_2           (), .cfg_shift_2 (),
.cfg_offset_3           (), .cfg_shift_3 (),
.cfg_offset_4           (), .cfg_shift_4 (),
.cfg_offset_5           (), .cfg_shift_5 (),
.cfg_offset_6           (), .cfg_shift_6 (),
.cfg_offset_7           (), .cfg_shift_7 (),
...
.ml_event_valid         (1'b0),   // ml_policy.v is S6 (S1.3)
.ml_adverse_pulse       (1'b0),
.ml_benign_pulse        (1'b0),
.ml_safe_forced_pulse   (1'b0),

// new:
.cfg_ml_th_high         (cfg_ml_th_high),
.cfg_ml_th_low          (cfg_ml_th_low),
.cfg_ml_score_offset    (cfg_ml_score_offset),
.cfg_ml_score_shift     (cfg_ml_score_shift),
.cfg_ml_window          (),   // still no consumer, S1.4 -- leave tied off
.cfg_offset_0 (cfg_offset_0), .cfg_shift_0 (cfg_shift_0),
.cfg_offset_1 (cfg_offset_1), .cfg_shift_1 (cfg_shift_1),
.cfg_offset_2 (cfg_offset_2), .cfg_shift_2 (cfg_shift_2),
.cfg_offset_3 (cfg_offset_3), .cfg_shift_3 (cfg_shift_3),
.cfg_offset_4 (cfg_offset_4), .cfg_shift_4 (cfg_shift_4),
.cfg_offset_5 (cfg_offset_5), .cfg_shift_5 (cfg_shift_5),
.cfg_offset_6 (cfg_offset_6), .cfg_shift_6 (cfg_shift_6),
.cfg_offset_7 (cfg_offset_7), .cfg_shift_7 (cfg_shift_7),
...
.ml_event_valid         (ml_event_valid),
.ml_adverse_pulse       (ml_adverse_pulse),
.ml_benign_pulse        (ml_benign_pulse),
.ml_safe_forced_pulse   (ml_safe_forced_pulse),
```

### 7.4 `tb/tb_tob_top.v` — new case

Add at least one new directed case (`T-`-numbered following the existing
`T1`–`T5` convention) proving the ML branch is live at board level: set
`cfg_ml_th_high`/`cfg_ml_th_low` via CSR writes to values that make a
specific driven message sequence's `z` cross `T_high` (hand-compute `z`
from the placeholder `w_i=1, b=0` model exactly as §3.4/§6 do), set
`cfg_ml_action=0` (block mode) via `ML_CTRL`, drive a message sequence
that both produces a `signal_engine.v` order intent AND an adverse ML
verdict on the *same* triggering event, and confirm the resulting order
frame's `reject_reason = 0x09` — the first true end-to-end proof that
gate `0x09` is no longer permanently dead (`adverse_risk` tied to
`1'b0`). A second case with `cfg_ml_action=1` (reduce mode) and
`cfg_ml_reduce_shift` set confirms the order still transmits but with the
reduced quantity (`risk_engine.v`'s existing D16 reduce-path arithmetic —
unchanged by this contract, just finally reachable).

## 8. `scripts/run_sim.sh`

Add, alongside the existing per-module entries:

```bash
run_tb tb_delay_line rtl/common/delay_line.v
run_tb tb_ml_classifier_wrap rtl/ml_classifier_wrap.v
run_tb tb_ml_policy rtl/ml_policy.v
run_tb tb_ml_chain rtl/tob_engine.v rtl/feature_extractor.v rtl/feature_normalizer.v rtl/ml_classifier_wrap.v rtl/ml_policy.v
```

and add the new Python golden-model regression alongside the two existing
`sim/test_*_handcase.py` lines:

```bash
python sim/test_ml_golden_handcase.py && pass "sim/test_ml_golden_handcase.py" || fail "sim/test_ml_golden_handcase.py"
```

`tob_top.v`'s existing `run_tb tb_tob_top` line needs `rtl/feature_extractor.v
rtl/feature_normalizer.v rtl/ml_classifier_wrap.v rtl/ml_policy.v
rtl/common/delay_line.v` added to its file list (it now instantiates all
five).

## 9. Acceptance criteria

- [ ] Every new/modified file compiles with `iverilog -g2001 -Wall`, zero
      warnings: `tb_delay_line`, `tb_ml_classifier_wrap`, `tb_ml_policy`,
      `tb_ml_chain`, `tb_tob_top` (full file list per §8).
- [ ] `python sim/test_ml_golden_handcase.py` passes.
- [ ] Every §3.4/§4.4 hand-computed value matches across all three of:
      the Verilog testbench, `sim/ml_golden.py`'s handcase test, and (for
      the ones reused in §6) `tb_ml_chain.v` — this is the "RTL ==
      `ml_golden.py` bit-exact" gate the master spec's S6 row requires.
- [ ] `tb_tob_top.v`'s new gate-`0x09` case (§7.4) shows `reject_reason =
      0x09` for the block-mode case and a reduced `order_qty` for the
      reduce-mode case.
- [ ] `RUN_SIM_FAST=1 bash scripts/run_sim.sh` reports `ALL TESTS PASSED`.
- [ ] `csr_block.v` is **not modified** by this contract (§1.2) — confirm
      `git diff rtl/csr_block.v` is empty.
- [ ] `risk_engine.v` is **not modified** by this contract — confirm
      `git diff rtl/risk_engine.v` is empty (only its `tob_top.v`
      instantiation's port connections change).
- [ ] No inferred latches in any new module; every `reg` assigned on
      every path or has a clear default.

## 10. Explicitly out of scope

- The real hls4ml IP, or any `hls4ml/`/`model/train.py` work — S4,
  unstarted, someone else's milestone. `ml_classifier_wrap.v`'s internals
  are the only thing that changes when S4 lands; its port list does not.
- Per-event staleness fail-safe forcing in `ml_policy.v` (§1.4) —
  deferred, flagged, not silently dropped. `risk_engine.v`'s gate `0x05`
  already independently guarantees no stale order is ever emitted.
- Wiring `score_raw`/`risk_level` to any CSR-readable register or
  diagnostic frame (§1.4) — no consumer exists yet.
- Giving `cfg_ml_window` (CSR `0x5C`) an RTL consumer (§1.4) — a
  pre-existing spec/implementation gap (D13's elaboration-time `WINDOW`
  parameter vs. this runtime register), not introduced or fixed here.
- The v2 MLP classifier (§5.4 of the master spec) — v1 only.
- Any change to `csr_block.v` or `risk_engine.v` — both already fully
  built for this integration (§1.2); this contract only wires them.
