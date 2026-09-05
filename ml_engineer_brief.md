# Tiny-ML Engineer Brief — Quantized Adverse-Selection Classifier

**What this is:** your complete, self-contained brief for the machine-learning half of the project. Read this instead of the master spec. It tells you what to build, the exact numeric contract, how to run it through hls4ml, and what to hand back to the FPGA side.

| Field | Value |
| :-- | :-- |
| Project | `fpga-tick-to-trade-engine` (tick-to-trade datapath + in-path ML risk gate) |
| Your role | Train, quantize, export via hls4ml, verify bit-exact, hand off IP + artifacts |
| Your languages | Python only (Keras/TensorFlow, numpy, hls4ml). **Zero Verilog.** |
| You deliver to | the FPGA owner, who synthesizes the IP with Vitis and wires it into the datapath |
| Target device | Xilinx Artix-7 `XC7A35T-2FGG484I` (Vivado part string `xc7a35tfgg484-2`, confirm in S0) |
| Toolchain | hls4ml (Vitis backend), Vitis HLS 2023.x, Python 3.11+ |

---

## 1. Your job, in one paragraph

The FPGA runs a market-data → order pipeline. You build a **quantized classifier** that estimates, for each quote decision, whether it is likely to be adversely selected in the short term. That estimate becomes **one bit** (`adverse_risk`) that feeds an additional, non-bypassable risk gate (`0x09`) in the fast path. Your output is not "a model that trades" — it is a fixed-point inference block, exported as a Vitis HLS IP, whose arithmetic is bit-exactly reproducible. The core rule:

> **The ML model may recommend blocking an order; deterministic hard logic decides whether the order is permitted.**

You own everything from training data to the exported IP. The FPGA owner owns everything in RTL and the actual gate logic.

---

## 2. Where your model sits

```text
Top-of-book state  ──►  feature_extractor (RTL) ──► feature_normalizer (RTL)
                                                        │  8 × int8 features
                                                        ▼
                                  [YOUR MODEL]  Dense(8→1), linear, int8 weights
                                                        │  int32 score z
                                                        ▼
                                   ml_policy (RTL): hysteresis threshold → adverse_risk
                                                        ▼
                                              risk gate 0x09  (RTL)
```

Three critical boundary facts:

1. **Feature extraction and normalization are done in RTL, not in your model.** Your hls4ml model is literally a single `Dense(8→1, linear)` layer. The FPGA computes the 8 features and normalizes them to `int8` before they reach your model.
2. **You still own the normalization *parameters*.** You choose and export the per-feature `offset_i` and `shift_i` that the RTL normalizer will apply. Your training must apply the *identical* normalization.
3. **Threshold and hysteresis are done in RTL, not in your model.** You export a *recommended* threshold `T_high` (and `T_low`), but the comparison lives in `ml_policy.v`, so it can be tuned at runtime without re-synthesizing your IP.

So your hls4ml model is: **8 int8 inputs → one int32 output (`z`).** Nothing else.

---

## 3. What you build — v1 model

A linear classifier (logistic regression without the sigmoid):

```text
z = b + Σ_{i=0..7} w_i · x_i
```

The sigmoid is omitted because it is monotonic: comparing `z` to a threshold gives the identical class decision as comparing a probability to a probability threshold. The Keras model is:

```python
model = keras.Sequential([
    keras.layers.Input(shape=(8,)),
    keras.layers.Dense(1, use_bias=True, activation='linear'),
])
```

**v2 (only after v1 is fully verified):** `x → Dense(8, ReLU/clamp) → Dense(1) → threshold`, with 4–8-bit weights/activations and quantization-aware training. Do not start v2 until v1 is bit-exact and measured.

---

## 4. The eight features (exact definitions)

For a watched symbol at event `t`, with best bid `b_t`, best ask `a_t`, bid size `q_{b,t}`, ask size `q_{a,t}`:

| ID | Feature | Formula | Pre-normalization type |
| :-- | :-- | :-- | :-- |
| F0 | Spread | `a_t − b_t` | unsigned, ticks |
| F1 | Mid-price delta | `m_t − m_{t−1}` where `m_t = (b_t + a_t) >> 1` | signed, ticks |
| F2 | Book imbalance | `q_{b,t} − q_{a,t}` (v1, no division) | signed |
| F3 | Bid-size change | `q_{b,t} − q_{b,t−1}` | signed |
| F4 | Ask-size change | `q_{a,t} − q_{a,t−1}` | signed |
| F5 | Update rate | number of book updates in the last `W` events | unsigned, clipped |
| F6 | Last trade direction | buy = +1, sell = −1, none = 0 | signed |
| F7 | Short-term volatility | sum of \|mid deltas\| over the last `W` events | unsigned, clipped |

**Mid price is integer everywhere:** `m_t = (b_t + a_t) >> 1` (floor). No floating point in the feature pipeline.

**Pin these down explicitly in your code and record them in `model_config.json`** (the FPGA owner matches you bit-for-bit, so ambiguity is a bug):

- **Window `W`** (for F5/F7): default 16; allowed 4/8/16/32. **Resolved** (`docs/design_decisions.md` D13, pinned during S3 contract-writing since it blocked a bit-exact `feature_extractor.v` contract): one W-deep sliding window per symbol, shared by F5/F7, advancing on **every accepted event of any `msg_type`** (quote/clear/trade/heartbeat), not only book-modifying ones — the current event's own contribution is included in that same event's output ("as of and including now"). Each slot records `(is_update, |F1|)`; `is_update` is true only for quote/clear. F5 = count of `is_update` slots in the window; F7 = sum of `|F1|` over the window. A book-clear resets `prev_bid`/`prev_ask`/the window to all-zero, then is itself treated as the first event after reset. `sim/feature_golden.py`'s `FeatureTracker` is the reference implementation — match it bit-for-bit, don't re-derive from this paragraph.
- **Initial state:** before the first update for a symbol, `m_{t−1}`, `q_{b,t−1}`, `q_{a,t−1}` are undefined → define F1 = F3 = F4 = 0 and F7 = 0 for the first event (hardware resets to zero; match it).
- **F6:** updated only by trade-print messages (aggressor side); persists across book updates until the next trade.
- **Reset/clear:** a book-clear resets the feature history to the initial state.

Your `ml_golden.py` is the *definition* of these semantics. Whatever it does, the RTL must match. Make it unambiguous.

---

## 5. The label (exact definition)

For a quote decision at event `t`, with integer mid `m_t`:

```text
buy label:   y_buy  = 1  if  m_{t+H} − m_t ≤ −1   else 0
sell label:  y_sell = 1  if  m_{t+H} − m_t ≥ +1   else 0
```

`H` is a fixed number of subsequent market-data **events** (20, 50, or 100 — pick one and record it), not wall-clock time.

**Say this out loud in every write-up:** this is a *proxy* label. A production adverse-selection model conditions on actual fills, queue position, and depth. Without real fill data, "adverse selection" here means "mid moved ≥ 1 tick against the quoted side within H events." The project is explicitly a controlled test of the FPGA inference path, not evidence about real markets.

---

## 6. Data — synthetic, deterministic, reproducible

Build a deterministic Python generator (`model/simulator.py`) that produces sequences of book updates (bid/ask price and size over time) covering:

- balanced book, stable mid
- bid depletion followed by a downward move
- ask depletion followed by an upward move
- wide spreads / low liquidity
- high update-rate / volatile periods
- spoof-like size changes (labeled as synthetic)
- bursts, stale intervals, sequence gaps, malformed events

Every generated event carries, at minimum: `sequence_number`, `symbol_id`, book state, the 8 raw feature values, the label, and (later) the expected classifier output.

**Reproducibility is a hard requirement:** a fixed seed must reproduce the exact same dataset. The seed is recorded in every results file.

### Model quality baselines (Phase B)

Train and compare, in this order, on the synthetic set:

1. hand-tuned threshold rule (no learned weights)
2. floating-point logistic regression
3. quantized logistic regression (the v1 deliverable)
4. *(optional)* quantized 8×8×1 MLP

Report precision/recall/F1, ROC-AUC (or PR-AUC if classes are imbalanced), confusion matrix, and an economic-proxy comparison (risky quotes avoided vs. benign quotes suppressed). Frame results as synthetic-proxy, not real-market.

---

## 7. Precision & quantization contract (read carefully — this is where projects break)

Every number below is a **hard contract**. The RTL and `ml_golden.py` must agree bit-for-bit.

### 7.1 Formats

| Quantity | Format | Range |
| :-- | :-- | :-- |
| Normalized feature `x_i` | signed 8-bit (`int8`) | −128 … 127 |
| Weight `w_i` | signed 8-bit (`int8`) | −128 … 127 |
| Product `w_i · x_i` | signed 16-bit (`int16`) | exact; fits in int16 |
| Bias `b` | signed 32-bit (`int32`) | aligned to accumulator |
| Accumulator / score `z` | signed 32-bit (`int32`) | 8 products + bias; no overflow at 32 bits |
| Threshold `T_high`, `T_low` | signed 32-bit | compare `z` to `T` directly |

Max |sum of products| = 8 × 16384 = 131072, so int32 is comfortably wide. **Use int32 for `z` and never let the toolchain silently truncate below 32 bits.**

### 7.2 Normalization (owned by you, applied in RTL)

```text
x_i = saturate_{[-128,127]}( (raw_i − offset_i) >> shift_i )
```

- `offset_i`: signed 32-bit (typically the training-set mean or a chosen baseline).
- `shift_i`: power-of-two scaling; only powers of two (no division hardware).
- `>>`: **arithmetic right shift, rounding toward −∞** (floor). In Python use `np.right_shift(...)` or `// (2 ** shift)`, **never** `int(v / 2**shift)` (that truncates toward zero and will diverge from hardware for negative values).
- `saturate`: clamp to [−128, 127]; **never wrap**.
- Record every `offset_i`, `shift_i`, and the floor-shift convention in `model_config.json`. These go into the FPGA's `ML_OFFSET_*` / `ML_SHIFT_*` registers.

### 7.3 Quantization procedure (do it in this order, don't skip steps)

1. Train the floating-point baseline.
2. Freeze feature definitions and preprocessing (normalization offsets/shifts).
3. Quantize weights to `int8`, bias to `int32`.
4. Re-evaluate on validation with **exact fixed-point arithmetic** (a small numpy implementation of §7.2, not the float model).
5. Export weights, bias, offsets, shifts, thresholds, and golden vectors.
6. **After this point, do not change any arithmetic semantics.** Changing a shift or a width invalidates every golden vector downstream.

---

## 8. The hls4ml flow

### 8.1 Setup

```bash
pip install hls4ml
# Vitis HLS 2023.x installed and on PATH (the FPGA owner can confirm the exact version)
```

### 8.2 Convert

Target configuration (verify exact knobs against the hls4ml docs for your version, and **pin versions**):

```python
import hls4ml

config = hls4ml.utils.config_from_keras_model(model, granularity='name')
config['Backend'] = 'Vitis'                    # not 'Vivado' — synthesized with Vitis
config['Part']    = 'xc7a35tfgg484-2'          # confirm exact string in S0
config['ClockPeriod'] = 8                      # 125 MHz
config['IOType']  = 'io_parallel'             # 8 features arrive in parallel in one cycle
config['Model']['ReuseFactor'] = 1
config['Model']['Precision']   = 'ap_fixed<8,8>'   # int8 features/weights (0 fractional bits)

hls_model = hls4ml.converters.convert_from_keras_model(model, hls_config=config)
```

The exact config keys differ slightly between hls4ml versions; when you pin your version, mirror the docstring for `convert_from_keras_model` rather than trusting this snippet verbatim.

Two things to confirm during S0 and record in `docs/hls4ml_flow.md`:

1. **Accumulator width.** Ensure the `Dense` result/accumulator precision is set to 32 bits (e.g. `ap_fixed<32,32>` or `ap_int<32>`). This is the single most common source of silent bit-error. Check the generated top function's data types.
2. **Fixed latency.** Verify the generated pipeline is stall-free and fixed-latency (a single `Dense` with `io_parallel` and `ReuseFactor=1` should be a combinational MAC + register). It must have data-independent latency — this is NFR-14 of the master spec.

### 8.3 Verify bit-exactness (your hard gate — do not hand off without this)

```python
# Run the C simulation (csim) on your exported golden vectors
y_csim  = hls_model.predict(x_golden)      # or hls_model.trace(x_golden) for intermediate values
y_py    = ml_golden_model(x_golden)        # your fixed-point numpy reference
assert (y_csim == y_py).all()              # MUST be bit-exact
```

`hls_model.predict()` / `.trace()` run the generated C++ in simulation. Require bit-exact agreement with `ml_golden.py` on **every** golden vector before you export the IP.

### 8.4 Export the IP

```python
hls_model.build()   # runs Vitis HLS synthesis → produces the RTL / IP
```

Hand off the exported IP (`.xo` / RTL directory) plus the interface description (§9).

---

## 9. The hardware contract you hand off

### 9.1 What you export (files)

```text
model/
├── model_config.json      # formats, offsets, shifts, W, H, thresholds, seed, versions
├── weights.mem            # 8 × int8 weights, one per line
├── bias.mem               # 1 × int32 bias
├── normalization.mem      # 8 offsets (int32) + 8 shifts
├── thresholds.mem         # T_high, T_low (int32)
├── golden_vectors.csv     # x (8 int8) → z (int32), plus adverse_risk for a chosen threshold
├── simulator.py           # deterministic data generator
├── train.py               # training + quantization
└── ml_golden.py           # fixed-point reference (the definition of the arithmetic)
```

Plus the exported Vitis HLS IP.

### 9.2 The IP interface (what the FPGA owner will instantiate)

- **Inputs:** 8 parallel signed 8-bit values (`x0..x7`), plus a clock/reset and — for `io_parallel` — an input-valid/start signal. No handshake blocking; `ap_ctrl_none`-style (lowest latency) is preferred.
- **Outputs:** `z` (signed 32-bit) and a done/valid flag.
- The FPGA owner wraps this in `ml_classifier_wrap.v` and registers the output.

You do **not** wire anything; you only need to document the port names/types/order so the wrapper matches.

### 9.3 What is NOT your job

- The threshold/hysteresis (`ml_policy.v`) — you provide recommended `T_high`/`T_low` only.
- The normalization arithmetic (`feature_normalizer.v`) — you provide `offset_i`/`shift_i` only.
- The risk gate logic, the datapath, the Ethernet, the book state — all FPGA owner.

---

## 10. Deliverables checklist (acceptance criteria)

Hand-off is complete when **all** of these are true:

- [ ] Synthetic dataset reproducible from a documented seed.
- [ ] `ml_golden.py` implements §7 exactly (int8→int32, floor shift, saturation, no wrapping).
- [ ] Float and quantized metrics reported (F1 / ROC-AUC / confusion matrix) with the honest proxy-label caveat.
- [ ] hls4ml converts with `backend='Vitis'`, `part='xc7a35tfgg484-2'`, `io_parallel`, 32-bit accumulator.
- [ ] `hls_model.predict()/trace()` **bit-exact** vs. `ml_golden.py` on every golden vector.
- [ ] Vitis HLS synthesis completes on the target part with the DSP budget met (≤ 8 DSP48 for v1; ≤ 16 for v2).
- [ ] IP exported + `model_config.json`/`.mem` files complete and internally consistent (weights count = 8, offsets/shifts count = 8, W/H/seed/versions recorded).
- [ ] Versions pinned (hls4ml, Keras/TF, numpy, Vitis HLS) in `docs/hls4ml_flow.md`.

---

## 11. Division of responsibility

| Item | You (ML) | FPGA owner |
| :-- | :--: | :--: |
| Synthetic data + labels | ✅ | — |
| Training + quantization | ✅ | — |
| `ml_golden.py` fixed-point reference | ✅ | reviews |
| hls4ml convert + bit-exact verify + export IP | ✅ | — |
| Feature extraction / normalization **arithmetic** (RTL) | defines semantics | implements |
| Normalization **parameters** (offsets/shifts) | ✅ | loads into registers |
| Threshold/hysteresis **logic** (RTL) | — | implements |
| Threshold **values** (recommended) | ✅ | tunes at runtime |
| Gate 0x09, datapath, Ethernet, book state | — | ✅ |
| End-to-end bit-exact soak | ✅ (ML side) | ✅ (RTL side) |

---

## 12. Your milestones (parallel track)

You are **not** on the FPGA owner's critical path. Your track runs in parallel with their parser/book work.

| Stage | Owner | Work | Gate |
| :-- | :-- | :-- | :-- |
| **S1** | You + FPGA | Freeze §4/§5 semantics together; `ml_golden.py` skeleton; seed + hand-computed 20-event case | Both golden models agree on the hand case |
| **S4** | You | Full training + quantization; export golden vectors; hls4ml convert + `trace()` bit-exact | T28/T29/T35 (golden) pass; hls4ml builds clean on the part |
| **S6** | Both | Hand off IP; FPGA owner integrates; joint bit-exact verification | RTL == `ml_golden.py` on all vectors |
| **S12** | Both | Metrics, baselines table, write-ups | Publish |

If hls4ml blocks at S6, the FPGA owner has a hand-written `linear_classifier.v` fallback behind the same wrapper — your golden vectors are still the reference. Do not let your schedule slip because of toolchain friction; your golden vectors + `ml_golden.py` are the real deliverable, the IP is the packaging.

---

## 13. Pitfalls (the ways this silently fails)

1. **Truncation vs. floor on negative shifts.** `int(v / 2**s)` ≠ `v >> s` for negative `v`. Use `np.right_shift`. This is the #1 bit-exactness bug.
2. **Accumulator narrower than 32 bits.** A 24-bit accumulator overflows at 8 × int8 products + bias. Check the generated C++ types.
3. **Changing arithmetic after exporting golden vectors.** Any change to an offset/shift/width invalidates everything downstream. Freeze at step 6 of §7.3.
4. **Window semantics.** Already pinned — see §4 and `docs/design_decisions.md` D13 (current event included; window advances on every event, not just book-modifying ones). Match `sim/feature_golden.py`, don't re-derive.
5. **Unpinned versions.** hls4ml/Keras/Vitis HLS versions change arithmetic behavior. Pin and record.
6. **DSP budget.** v1 = 8 MACs (≤ 8 DSP48, fine). v2 8×8×1 ≈ 72 MACs vs. the part's 90 DSPs — plan reuse or LUT multipliers, or you will not fit.
7. **Overclaiming.** Say "synthetic proxy label" every time. A real practitioner will find the weakness in 30 seconds; owning it reads as maturity.

---

## 14. Quick start (today)

```bash
pip install hls4ml numpy h5py pyyaml
# 1. Write model/simulator.py  — deterministic book-update generator + labels
# 2. Write model/train.py       — float logistic regression, then quantize (§7.3)
# 3. Write model/ml_golden.py   — fixed-point reference (§7)
# 4. Convert + verify (§8.2–8.3) — get bit-exact BEFORE touching anything else
```

Your first milestone is small and concrete: **produce a hand-computed 20-event case where `ml_golden.py` and the training path agree, with a fixed seed.** Everything else grows from that.
