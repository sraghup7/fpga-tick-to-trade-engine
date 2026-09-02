# fpga-tick-to-trade-engine

**A low-latency market-data-to-order datapath with a quantized hls4ml-generated adverse-selection classifier as an in-path risk gate, on an Artix-7 FPGA.**

A pipelined FPGA that receives a synthetic Gigabit-Ethernet market-data feed, parses and filters it, maintains top-of-book state, extracts fixed-point features, runs a quantized ML classifier, gates the resulting order intent through deterministic risk checks (including the ML verdict), and emits a simulated order — at a **measured, fixed tick-to-trade latency**, verified bit-exact against a Python golden model.

> **Status: spec-complete, pre-implementation.** The master specification (`docs/master_spec.md`) is finished and covers the full design, requirements traceability, and verification plan. RTL, simulation, and Python tooling land on the `develop` branch as the implementation proceeds. See [Roadmap](#roadmap).

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
├── docs/                               # (planned) block diagram, latency budget, decisions
├── rtl/                                # (planned) Verilog-2001, one module per stage
├── sim/                                # (planned) golden models, feed generator, comparer
├── model/                              # (planned) training, quantization, exported weights
├── tb/                                 # (planned) self-checking testbenches
├── hls4ml/                             # (planned) generated project, rebuilt by script
├── scripts/  constraints/  results/    # (planned) build, XDC, published measurements
```

---

## Reproducing results

No code yet — the design is fully specified but pre-implementation. The plan:

```bash
make sim      # run all self-checking tests against the golden model
make synth    # headless Vivado synthesis + timing closure at 125 MHz
make bit      # place-and-route → bitstream
make all      # full flow
```

Success criteria (defined in the master spec §1.6): line-rate processing of ≥ 1,000,000 messages with zero drops; a **single-occupancy latency histogram** (max == min); every risk gate individually demonstrated blocking; bit-exact RTL vs. golden model on a randomized soak; WNS > 0 at 125 MHz; one-command reproduction from a clean clone.

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

| Stage | Milestone |
| :-- | :-- |
| S0–S1 | Repo scaffold, message format, golden models |
| S2–S3 | Parser, filter, book, feature extraction |
| S4 | ML training, quantization, hls4ml export (parallel track) |
| S5–S9 | Signal, ML integration, risk, egress, instrumentation |
| S10–S11 | Integration, timing closure, hardware bring-up |
| S12 | Publish: README, results tables, demo video |

## License

Apache-2.0 (LICENSE to be added).
