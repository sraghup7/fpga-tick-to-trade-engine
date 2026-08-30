# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**Spec-only, pre-implementation.** There is no `rtl/`, `sim/`, `tb/`, `model/`, or `hls4ml/` yet, and no build/test/lint tooling exists. Do not assume any command (`make`, `pytest`, Vivado, Vitis HLS, etc.) works — check the filesystem before claiming otherwise. The eventual layout is defined in `fpga_tick_to_trade_master_spec.md` §13.

This is a FPGA market-data-to-order engine: a synthetic Gigabit-Ethernet feed is parsed, top-of-book state is maintained, fixed-point features are extracted, a quantized (hls4ml-generated) linear classifier estimates adverse-selection risk, and that estimate becomes one of nine non-bypassable pre-trade risk gates before a simulated order is emitted — all at a fixed, measured tick-to-trade cycle count. Nothing here touches real money or a real exchange.

## Authoritative documents — read in this order

1. **`fpga_tick_to_trade_master_spec.md`** — single source of truth (v2.0, merged master). Every design decision, requirement, and register/counter definition lives here. §0 has a reconciliation table against the two documents it superseded.
2. **`fpga_top_of_book_engine_spec.md`** — superseded historical document. Never edit it as authoritative; if a change affects material also described here, make the change in the master spec and update §0's reconciliation table instead.
3. **`ml_engineer_brief.md`** — self-contained handoff for the ML/hls4ml collaborator (Python + hls4ml only, no Verilog). Mirrors §5–§11 of the master spec from the ML side. Keep it in sync whenever the ML contract (features, label, quantization, IP interface) changes in the master spec.
4. **`README.md`** — the public-facing deliverable (architecture diagram, wire format, decision rule, risk table, reproduction commands, results, limitations). Update it when the master spec's user-facing facts change; it is explicitly listed as a deliverable in §13.

Do not maintain a second, parallel spec. If a fact needs to change, change it at its source document and let the others reference it.

## Spec editing conventions

- Requirements are numbered `FR-n` (functional, §6) and `NFR-n` (non-functional, §7). **Every requirement must map to at least one test in §11.4** — adding a requirement without a corresponding test breaks the traceability model the spec is built around.
- Measured numbers (latency cycles, resource utilization, timing slack) belong in the §12 tables only, never asserted in prose elsewhere in the spec or README.
- §0's reconciliation table records every deliberate behavior change versus the original (now-superseded) specs — update it whenever a change alters previously-documented behavior.
- The register map (§9), counter set (§10), and directed test list (§11.4) are cross-referenced from RTL module names (§13's `rtl/` tree) — keep names consistent across all three when adding to any of them.

## Hard technical constraints for future code

- **Hand-written RTL is Verilog-2001 only** (synthesizable subset, no SystemVerilog), living under `rtl/` (NFR-9). The sole exception is Vitis-HLS/hls4ml-generated IP, which is wrapped by hand-written Verilog (`ml_classifier_wrap.v`), never edited directly.
- **Target device:** Xilinx Artix-7 `XC7A35T-2FGG484I` (ALINX AX7035B), Micrel KSZ9031RNX PHY (RGMII).
- **Single 125 MHz clock domain** for the whole engine (8 ns period). Toolchain: Vivado 2023.x+, Vitis HLS 2023.x+, Python 3.11+.
- **Prices and quantities are integer ticks**, never floating point, anywhere in RTL, the golden model, or the labeler — this is a deliberate exact-comparison / no-DSP decision for the fast path (see the master spec's key-decisions table).
- **ML is a risk gate, not the signal path.** The classifier produces a 1-bit `adverse_risk` verdict that gates the order intent through gate `0x09`; it can never override the kill switch, position limits, size limits, price band, staleness check, or sequence-gap check. Deterministic gates `0x01`–`0x08` always dominate the reported reject reason over `0x09`.
- **Fixed-depth, deterministic pipeline.** The signal path (~2 cycles) and the ML path (features → classifier → hysteresis, ~7–10 cycles) run in parallel after a book update; order intent is delayed through a fixed alignment register so both reach `risk_engine` in the same cycle. Any change to either path's depth must keep this alignment exact — tick-to-trade latency must stay a fixed constant (single-occupancy latency histogram: max == min).
- **hls4ml flow:** Python (Keras) → hls4ml (Vitis backend, part `xc7a35tfgg484-2`, `io_parallel`) → Vitis HLS IP. Weights/accumulator are `int8`/`int32`. The hls4ml C-simulation (csim) must be bit-exact against the Python fixed-point golden model on every exported golden vector before the IP is handed off — this is called out in `ml_engineer_brief.md` §8.3 as a hard gate, not a nice-to-have.
- **Golden models are written from the spec, not derived from the RTL** — a model derived from the RTL can only confirm the RTL matches itself.

## Planned repository layout (§13 of the master spec)

Not present yet, but referenced constantly in the specs — when creating these, match these paths/names exactly since the register map, test list, and ML brief all cross-reference them:

```
docs/            block_diagram.svg, latency_budget.md, fixed_point_contract.md, hls4ml_flow.md, design_decisions.md
rtl/             one module per pipeline stage (tob_top.v, frame_classifier.v, md_parser.v, symbol_filter.v,
                 seq_monitor.v, tob_engine.v, feature_extractor.v, feature_normalizer.v, ml_classifier_wrap.v,
                 ml_policy.v, signal_engine.v, risk_engine.v, order_builder.v, latency_histogram.v, csr_block.v,
                 common/ for sync_2ff.v, counter_sat.v, ...)
hls4ml/          generated project (gitignored, rebuilt by scripts/build_hls4ml.py)
tb/              tb_top.v, tb_<module>.v, stimulus/
sim/             golden_model.py, ml_golden.py, feed_gen.py, order_rx.py, compare.py
model/           train.ipynb/train.py, model_config.json, weights.mem, bias.mem, normalization.mem, golden_vectors.csv
constraints/     tob_pins.xdc, tob_timing.xdc
scripts/         build.tcl (headless Vivado), build_hls4ml.py, run_sim.sh, report.py
results/         utilization.md, timing.md, latency_histogram.csv, ml_metrics.md, ila_captures/
```

Planned `make` targets (not yet implemented): `make sim`, `make synth`, `make bit`, `make all`.

## Big-picture architecture (for orientation, see master spec §3 for full detail)

Ingress → parse → filter → book state, then **two convergent paths** running in parallel, realigned before risk:

```
md_parser → symbol_filter → seq_monitor → tob_engine
                                             ├─ feature_extractor → feature_normalizer(int8) → ml_classifier_wrap (hls4ml IP) → ml_policy(hysteresis) ─┐
                                             └─ signal_engine (spread + imbalance rule) ─────────────────────────────────────────[align]──┴→ risk_engine (9 gates, incl. 0x09 ML) → order_builder → eth_mac_tx
```

- **Decision rule:** after a book update, buy when `spread ≥ cfg_min_spread` and `bid_qty > (ask_qty << cfg_imb_shift)`; sell under the mirror condition; both require a valid, non-crossed book.
- **Wire format:** fixed-width 16-byte big-endian market-data messages (`msg_type`, `symbol_id`, `side`, `flags`, `price` u32, `quantity` u32, `seq_num`), 1–88 packed per Ethernet frame. Order-output frames carry `trigger_seq` and the measured `latency_cyc`, so the host's order capture doubles as a latency log.
- **ML model (v1):** linear classifier `z = b + Σ w_i·x_i` (monotonic, no sigmoid needed at inference), `int8` weights/features, `int32` accumulator, 8 fixed-point features computed in RTL (spread, mid-price delta, book imbalance, bid/ask size changes, update rate, last trade direction, short-term volatility). The adverse-selection label is a synthetic proxy (mid moves ≥1 tick against the quoted side within `H` future events) — it demonstrates the FPGA inference path, not real market microstructure. Never claim this predicts real adverse selection.
- **Honest limitations to preserve in any future docs/code comments:** simulated trading only; proxy ML label; optimistic immediate-fill model; snapshot-replace book (not incremental multi-level — that's v2).
