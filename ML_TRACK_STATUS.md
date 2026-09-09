# ML Track Status Report

Status of the quantized adverse-selection classifier (`ml_engineer_brief.md`), through roadmap Step 6 of the training/quantization hand-off. Covers the **ML track** only — data, features, labels, training, and quantization, run in Python and headed for an hls4ml/Vitis HLS hand-off. The **FPGA/RTL track** (parser, book, risk engine, Ethernet) is being built in parallel.

Repo `fpga-tick-to-trade-engine`, branch `develop`, latest pushed commit `e207750`, as of 2026-09-09.

## Headline numbers

| Metric | Value |
| :-- | :-- |
| Quote events (synthetic dataset) | 23,200 |
| Rows with a trading signal | 3,681 |
| Train / validation split | 2,541 / 1,140 |
| Positive rate | 52.9% |
| Precision | 0.599 |
| Recall | 0.721 |
| F1 | **0.654** |
| ROC-AUC | **0.569** |

Baseline for comparison — hand-tuned threshold rule (no learned weights): F1 = 0.164.

## Checkpoint 1.0 — foundations (commit `184c9e1`, 2026-09-01)

- `model/config.py` — froze the semantic decisions the brief leaves open: window `W=16` (current event included), label horizon `H=50`, dataset seed.
- `model/simulator.py` — deterministic synthetic market generator: balanced book, bid/ask depletion, wide spreads, high volatility, spoof-like size changes, bursty/gappy streams.
- `model/ml_golden.py` — the fixed-point reference: F0–F7 feature extraction, the y_buy/y_sell label, int8 normalization (floor-shift + saturate, not truncate — the brief's #1 pitfall), the int32 classifier score.
- 9 unit tests, all passing — including a hand-computed 20-event sanity case and a check that the floor-shift matches true Verilog arithmetic-shift semantics on negative numbers.

## Checkpoint 1.1 — training, and three bugs only real output caught (commit `e207750`, 2026-09-09)

Code review alone didn't surface any of these — each one only showed up once `train.py` actually ran end to end.

| # | Issue | Fix |
| :-- | :-- | :-- |
| 1 | **Degenerate label.** `LABEL_COMBINE="OR"` was true on ~97% of rows; all 8 weights rounded to 0, ROC-AUC = 0.500. | Added `intended_side()`: the master spec's actual FR-35/36 trading rule decides which one-sided label (buy or sell) applies; rows with no signal are dropped. |
| 2 | **Too little data** once labeling got honest. Side-conditioning left 174 usable rows out of 1,160 — too few to train or evaluate (ROC-AUC = 0.387, i.e. noise). | `SCENARIO_REPEATS=20` reruns the scenario set 20× (fresh symbols, same seeded stream) for 3,681 signal rows. |
| 3 | **Weight quantization collapsed to zero.** Learned float weights were all under 0.22 in magnitude; rounding to nearest int sent every one to 0, again. | Symmetric max-abs scaling: weights + bias scaled together so the largest weight uses the int8 range, before rounding. |
| 4 | **Training wasn't actually reproducible.** Keras seeds its own weight init from TensorFlow's global RNG, ignoring `config.SEED` — same data, different result each run. | `tf.keras.utils.set_random_seed(SEED)` — verified two full runs now produce byte-identical output. |

Final, on 1,140 held-out rows: **F1 0.654, ROC-AUC 0.569**. Modest but real; reported as a synthetic proxy-label result throughout, not a claim about real markets.

## Files in `model/`

| File | What it is | Status |
| :-- | :-- | :-- |
| `config.py` | Every frozen semantic/quantization constant, each documented at the point it's used. | source |
| `simulator.py` | Deterministic synthetic market-data generator. | source |
| `ml_golden.py` | Fixed-point reference: features, label, signal rule, normalize, classify. | source |
| `metrics.py` | Dependency-free precision/recall/F1/ROC-AUC/PR-AUC. | source |
| `train.py` | Train → quantize → re-evaluate in fixed point → export. | source |
| `tests/` (20 tests) | Fixed-point, metrics, and export-consistency tests — all passing. | source |
| `model_config.json` | Formats, offsets, shifts, weights, thresholds, versions. | exported |
| `weights.mem` / `bias.mem` | int8 weights, int32 bias — one value per line. | exported |
| `normalization.mem` | Per-feature offset/shift pairs for the RTL normalizer. | exported |
| `thresholds.mem` | Recommended T_high / T_low for the hysteresis gate. | exported |
| `golden_vectors.csv` | 1,140 x→z→adverse_risk rows for hls4ml bit-exactness checks. | exported |

## Roadmap

1. ~~Freeze definitions, simulator, golden model~~ — done
2. ~~Train, quantize, export~~ — done
3. **Convert with hls4ml** — Backend=Vitis, part `xc7a35tfgg484-2`, `io_parallel`; confirm the 32-bit accumulator survives conversion
4. Verify bit-exactness — `hls_model.predict()`/`.trace()` vs. `ml_golden.py` on every golden vector — the hard gate before export
5. Build and export the IP — package alongside `model_config.json` for the FPGA owner
6. Integrate and joint-verify — wire into `ml_classifier_wrap.v`, run an end-to-end bit-exact soak with the RTL track
