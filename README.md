# fpga-tick-to-trade-engine

**A low-latency market-data-to-order datapath with a quantized hls4ml-generated adverse-selection classifier as an in-path risk gate, on an Artix-7 FPGA.**

A pipelined FPGA that receives a synthetic Gigabit-Ethernet market-data feed, parses and filters it, maintains top-of-book state, extracts fixed-point features, runs a quantized ML classifier, gates the resulting order intent through deterministic risk checks (including the ML verdict), and emits a simulated order — at a **measured, fixed tick-to-trade latency**, verified bit-exact against a Python golden model.

> **Status: implementation in progress — milestones S0–S3, S5–S10 done; S11 (hardware bring-up) has a real, gate-passing bitstream for the first time, not yet tried on physical hardware** (2026-09-08). Every RTL stage through board-level integration (`tob_top.v`) is built and self-checking: parser, book/feature-extraction, signal engine, the ML fallback classifier + hysteresis policy (gate `0x09`), all nine risk gates, egress, the latency histogram, and the CSR control plane, each with a passing Icarus testbench, a full-system integration test (`tb/tb_top.v`), and a 1,000,000-message parser soak at zero loss. Real Vivado synthesis now closes timing at 125 MHz with 0 inferred latches (see `results/timing.md` / master spec §12.3 for the measured WNS/WHS) and `write_bitstream` completes — see `docs/design_decisions.md` D26–D44 for the full trace, including three real bugs the process found and fixed (a stale-alignment bug in the risk/ML gating, a mis-wired feed-health counter, and 15 of 22 board pins that were silently unconstrained). S4's training/quantization pipeline has landed (`docs/design_decisions.md` D52) -- gate `0x09` runs `ml_classifier_wrap.v` (still a hand-written fallback, not a real hls4ml IP) loaded with real trained weights, not the old `w_i=1` placeholder. See [Roadmap](#roadmap).

---

## Why this is a hardware problem

An FPGA turns tick-to-trade latency into a property of the circuit, not of a CPU's scheduler. Two properties matter and are frequently confused:

- **Latency** — how long a reaction takes.
- **Determinism** — how tightly that duration is bounded.

A strategy sized around a 2 µs reaction that occasionally takes 50 µs is periodically and unpredictably wrong — and those occasions correlate with exactly the busy moments when an opportunity existed. Determinism is often worth more than raw speed. This design is built as a fixed-depth pipeline: bytes enter and propagate through decode, book update, feature extraction, ML inference, signal, and risk, with a constant cycle count from input to output.

## The ML decision

The ML model does **not** replace the trading rule. It is a *risk signal*: a quantized classifier estimates whether a prospective quote is likely to be adversely selected in the near term, and that estimate gates the order as an additional, non-bypassable risk gate (`0x09`).

> **The ML model may recommend blocking an order; deterministic hard logic decides whether the order is permitted.**

The model can never override the kill switch, position limits, size limits, price band, staleness, or sequence-gap checks.

---

## Architecture

```text
   HOST PC (Python): feed_gen / order_rx / golden_model / train
        │  1000BASE-T
   ┌────▼────┐
   │  JL2121(D)  PHY  (RGMII @ 125 MHz)
   └────┬────┘
   ═════▼══════════════════════════════════════════════════
   FPGA — Artix-7 XC7A35T-2FGG484I, single 125 MHz domain
   ┌────────────────────────────────────────────────────┐
   │ [A] rgmii_to_gmii        DDR ↔ SDR conversion      │
   │ [B] eth_mac_rx           FCS check                 │
   │ [C] frame_classifier     EtherType / IPv4 / UDP    │
   │ [D] md_parser            byte-serial → message     │  ═ TIMESTAMP IN
   │ [E] symbol_filter        4-entry symbol CAM        │
   │ [F] seq_monitor          gap detection, staleness  │
   │ [G] tob_engine           best bid/ask registers    │
   │      ├──► [G2] feature_extractor    F0–F7          │
   │      │    [G3] feature_normalizer   → int8         │
   │      │    [P]  ml_classifier (hls4ml IP)           │
   │      │    [Q]  ml_policy        hysteresis         │
   │      └─────────────────────────────┐               │
   │ [H] signal_engine      spread + imbalance         │
   │      │                 │                          │
   │      │            [ALIGN] match ML path           │
   │      │                 │                          │
   │ [I] risk_engine        9 gates (incl. 0x09 ML)    │
   │ [J] order_builder      order → frame              │  ═ TIMESTAMP OUT
   │ [K] eth_mac_tx         FCS, IFG                   │
   │ ───────────────────────────────────────────────── │
   │ [L] latency_histogram  BRAM, 64 buckets           │
   │ [M] csr_block          config + counters          │
   │ [N] stats_reporter     periodic stats frames      │
   │ [O] debug_uart         fallback ingress           │
   └────────────────────────────────────────────────────┘
        │
    KEY[0] kill switch
```

**Two convergent paths.** After a book update, the signal path (deterministic rule, ~2 cycles) and the ML path (features → classifier → hysteresis, ~7–10 cycles) run in parallel. The order intent is delayed through a fixed-depth alignment register so the ML verdict and the order intent reach the risk engine **in the same cycle** — keeping tick-to-trade a fixed constant even with ML in the path.

---

## Key design decisions

| Decision | Rationale |
| :-- | :-- |
| Prices are integer ticks, never floats | Exact comparison, one LUT level, no DSP for price math |
| Snapshot-replace book updates | Book update stays one cycle; real add/modify/cancel is v2 |
| ML is a risk gate, not the signal | Model stays advisory; the decision path stays deterministic and testable |
| Threshold/hysteresis in RTL, weights in hls4ml IP | Runtime-tunable thresholds without re-synthesis; deterministic logic stays in Verilog |
| Drop stale orders rather than queue them | A queued stale order trades on outdated information; an unbounded queue would make latency history-dependent |
| 2-deep order output register, not a deep FIFO | Bounds queueing, keeps latency deterministic, overflow is counted not hidden |
| Golden model written from the spec, not the RTL | A model derived from the RTL can only confirm the RTL does what the RTL does |

---

## Wire format

Fixed-width 16-byte big-endian market-data messages, 1–88 packed per Ethernet frame.

| Offset | Field | Description |
| :-- | :-- | :-- |
| 0 | `msg_type` | `0x01` quote, `0x02` trade, `0x03` book clear, `0xFF` heartbeat |
| 1 | `symbol_id` | 8-bit instrument ID |
| 2 | `side` | `0x00` bid/buy, `0x01` ask/sell, `0xFF` N/A |
| 3 | `flags` | bit0 end-of-burst, bit1 snapshot, rest reserved |
| 4 | `price` | Price in ticks, unsigned 32-bit |
| 8 | `quantity` | Size, unsigned 32-bit |
| 12 | `seq_num` | Monotonic per feed |

Orders are emitted as one 16-byte frame each, carrying `trigger_seq` and the measured `latency_cyc` — so the host's capture of the order stream is simultaneously a latency log.

---

## Trading rule and risk gates

**Decision rule (one line):** after a book update, buy when `spread ≥ cfg_min_spread` and `bid_qty > (ask_qty << cfg_imb_shift)`; sell under the mirror condition; both with a valid, non-crossed book.

**Nine pre-trade risk gates**, all non-bypassable, evaluated in parallel in the fast path:

| ID | Gate | ID | Gate |
| :-- | :-- | :-- | :-- |
| `0x01` | Kill switch | `0x06` | Sequence gap |
| `0x02` | Max order size | `0x07` | Crossed/locked book |
| `0x03` | Max position | `0x08` | Order-rate throttle |
| `0x04` | Price band | `0x09` | **Adverse selection (ML)** |
| `0x05` | Stale data | | |

Gate `0x09` blocks (or optionally reduces the size of) an order when the quantized classifier flags elevated adverse-selection risk. Deterministic hard gates (`0x01`–`0x08`) always dominate the reported reject reason.

---

## The ML subsystem

- **Model (v1):** linear classifier `z = b + Σ w_i·x_i`, sigmoid-free (monotonic), weights `int8`, accumulator `int32`.
- **Features (8):** spread, mid-price delta, book imbalance, bid/ask size changes, update rate, last trade direction, short-term volatility — all fixed-point, computed in RTL.
- **Label (proxy, honest):** for a quote at event `t`, adverse if the integer mid moves ≥ 1 tick against the quoted side within `H` future events. This is a *synthetic proxy* — without real fill data it demonstrates the inference path, not real market behavior.
- **Flow:** Python (Keras) → **hls4ml** (`Vitis` backend, `xc7a35tfgg484-2`, `io_parallel`) → Vitis HLS IP → wrapped in Verilog behind `ml_classifier_wrap.v`.
- **Verification:** the hls4ml C simulation (`trace`/`predict`) must agree bit-exactly with the Python fixed-point golden model on every exported golden vector.

The ML engineer's self-contained brief is `ml_engineer_brief.md`.

---

## Repository layout

```
├── fpga_tick_to_trade_master_spec.md   # single source of truth (design + traceability)
├── ml_engineer_brief.md                # ML collaborator handoff (Python/hls4ml only)
├── AGENTS.md                           # instructions for AI-assisted development
├── docs/                               # design_decisions.md (44 entries), contracts/ (per-module handoffs)
├── rtl/                                # Verilog-2001; every stage through board-level tob_top.v is built, incl. ML fallback + risk gate 0x09
├── sim/                                # golden_model.py, feature_golden.py, ml_golden.py, order_rx.py, gen_top_soak_vectors.py + hand-case tests; compare.py not yet
├── model/                              # weights.mem/bias.mem: real trained, quantized weights (S4 landed, D52) -- hls4ml export itself is still not done, so `ml_classifier_wrap.v`'s hand-written fallback is what actually runs them
├── tb/                                 # self-checking testbenches, one per landed module, plus tb_top.v (full-system integration test)
├── hls4ml/                             # (not yet — generated project, rebuilt by script once S4 lands)
├── scripts/  constraints/  results/    # build.tcl (Vivado, non-project mode)/run_sim.sh done; build_hls4ml.py/report.py not yet; results/build/ has a real, passing timing report and tob_top.bit
```

---

## Reproducing results

The datapath through egress (parser → book → features → signal → risk → order framing) is implemented and self-checking today:

```bash
make sim          # everything: golden models, RTL lint, every testbench, 1M-message soak
RUN_SIM_FAST=1 make sim   # same, skipping the slow 1M-message soak

make synth        # real Vivado synth+impl via scripts/build.tcl (non-project mode) -- now
                  # closes timing with 0 latches (measured numbers: results/timing.md)
make bit          # same target as synth; writes results/build/tob_top.bit once the gates pass -- they do
python scripts/report.py   # (after a build) refreshes results/timing.md and results/utilization.md

# or decode an order capture directly:
python sim/order_rx.py --in some_capture.hex
python sim/order_rx.py --udp 5006   # live, once S11 hardware bring-up sends real traffic
```

`make ml` runs the real training pipeline (`model/train.py`, then regenerates RTL bit-exactness vectors). `make synth`/`make bit` are real and now pass their own gates (zero latches, non-negative setup/hold slack) end to end — `results/build/tob_top.bit` is a real, gate-passing bitstream, produced for the first time this session. It has not yet been loaded onto physical hardware.

Success criteria (defined in the master spec §1.6): line-rate processing of ≥ 1,000,000 messages with zero drops — **met** for the parser stage; a **single-occupancy latency histogram** (max == min) — histogram module built and tested in simulation (S9), not yet measured on real hardware; every risk gate individually demonstrated blocking — **met** in simulation for all nine gates, including `0x09` (ML), now against real trained weights (D52), verified bit-exact against `model/golden_vectors.csv` via `tb/tb_ml_bit_exact.v`; bit-exact RTL vs. golden model on a randomized soak — **met** in simulation for the 1,000,000-message parser-stage soak; the full-system pass (`tb/tb_top.v`) now runs 5,000 messages (up from 209, D51) and is bit-exact on 33/35 counters with one known, documented, non-blocking discrepancy in dense-burst TX-queue-overflow prediction (see `docs/design_decisions.md` D51); WNS ≥ 0 at 125 MHz — **met** after place-and-route (measured value: `results/timing.md` / master spec §12.3, not restated here — it's thin margin, worth reading in full rather than skimming a headline number); one-command reproduction from a clean clone — **met for simulation** (`make sim`), and `make synth`/`make bit` now run the real, reproducible Vivado flow through a passing bitstream.

## Honest limitations

- **Simulated trading only.** Never connects to a real exchange, never handles money. The "exchange" is a Python program.
- **Proxy ML label.** The adverse-selection label is based on future mid-price movement in synthetic data, not real fills. This project demonstrates an FPGA inference path, not real market microstructure.
- **Optimistic fill model.** v1 assumes immediate full fill at the emitted price.
- **Snapshot-replace book.** Not an incremental multi-level order book (that is v2).

---

## Documentation

- **`fpga_tick_to_trade_master_spec.md`** — the master spec: 59 functional and 14 non-functional requirements, module specifications, risk engine, register map, counters, verification plan (36 tests), results-to-publish, and the two-person milestone plan.
- **`ml_engineer_brief.md`** — the ML collaborator's contract: features, label, quantization, hls4ml flow, deliverables.

## Roadmap

| Stage | Milestone | Status |
| :-- | :-- | :-- |
| S0–S1 | Repo scaffold, message format, golden models | Done |
| S2–S3 | Parser, filter, book, feature extraction | Done |
| S5 | Signal engine | Done (built ahead of S4/S6 — doesn't depend on ML) |
| S7 | Risk engine (9 gates) | Done |
| S8 | Egress (`order_builder`, framing) | Done — RTL, testbench, and `sim/order_rx.py` host-side decoder |
| S4 | ML training, quantization, hls4ml export (parallel track) | Training/quantization pipeline landed and fixed (D52); hls4ml export itself still not started -- gate `0x09` runs the hand-written fallback classifier loaded with real trained weights |
| S6 | ML integration (`ml_classifier_wrap`, `ml_policy`, alignment register) | Done — built ahead of S4, against the fallback classifier |
| S9 | Instrumentation (`latency_histogram`, `csr_block`, stats) | Done |
| S10 | Board-level integration (`tob_top.v`) | Done |
| S11 | Timing closure, hardware bring-up | Timing closed, first real gate-passing bitstream produced (`results/build/tob_top.bit`) — not yet tried on physical hardware |
| S12 | Publish: README, results tables, demo video | Not started |

## License

Apache-2.0 — see [LICENSE](LICENSE). This repo vendors one third-party
component (`rtl/vendor/alinx_mac/`, ALINX's own RGMII/Ethernet MAC
reference RTL) under separate terms — see [NOTICE](NOTICE) for its origin
and attribution.
