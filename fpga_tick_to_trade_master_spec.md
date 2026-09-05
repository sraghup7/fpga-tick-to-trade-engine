# Tick-to-Trade Engine with In-Path ML — Master Specification

**A low-latency market-data-to-order datapath with a quantized adverse-selection classifier as an in-path risk gate, on an Artix-7 FPGA**

| Field | Value |
| :-- | :-- |
| Version | 2.0 (merged master) |
| Supersedes | `fpga_top_of_book_engine_spec.md` v1.0 (the separate adverse-selection classifier spec has been removed from the repo) |
| Author | Sai Charan Raghupatruni (FPGA / bring-up) |
| Collaborator | TBD (ML / hls4ml) |
| Target device | Xilinx Artix-7 `XC7A35T-2FGG484I` (ALINX AX7035B) |
| Ethernet PHY | JLSemi JL2121(D), RGMII, 10/100/1000 Mbps — corrected 2026-09-01; the board's own schematic and every earlier doc here said Micrel KSZ9031RNX, which is wrong for the physically populated chip (see §0 reconciliation and `docs/design_decisions.md` D4) |
| RTL language | Verilog-2001 (synthesizable subset) for `rtl/`; the ML core is HLS-generated IP |
| ML flow | Python (Keras) → hls4ml → Vitis HLS IP |
| Toolchain | Vivado 2023.x or later, Vitis HLS 2023.x or later, Python 3.11+ |
| Core clock | 125 MHz (8 ns period), single clock domain for the engine |
| Planned effort | 8–12 calendar weeks, two-person, portfolio-grade deliverable |
| Repository name | `fpga-tick-to-trade-engine` |

---

## 0. How to use this document

This is the single source of truth for the project. Requirements are numbered (`FR-n`, `NFR-n`) and every requirement maps to at least one test in §11. When a design decision is made, record it here; when a number is measured, fill it into §12. Do not maintain a second, parallel spec.

**Section map:** §1 problem, §2 glossary, §3 architecture, §4 wire format, §5 the ML model, §6 functional requirements, §7 non-functional requirements, §8 risk engine, §9 register map, §10 counters, §11 verification, §12 results, §13 deliverables, §14 out-of-scope, §15 milestones, §16 risks, §17 open questions, §18 significance.

**Reconciliations vs. the original top-of-book spec (read once, then rely on this doc). The separate adverse-selection classifier spec is no longer in the repo; its content is merged here and the following rows record the resulting design decisions:**

| Topic | Old | New (this doc) |
| :-- | :-- | :-- |
| Projects | Two separate specs | One merged project; ML is a risk gate `0x09` |
| ML role | "recommends an action" | ML produces a 1-bit `adverse_risk` that gates the order intent; deterministic rules still decide |
| Tick-to-trade | ≤10 cycles | ≤22 cycles (ML runs in parallel; order intent is aligned to the ML verdict) |
| Fast-path DSP | 0 DSP | Signal/risk path still 0 DSP; the classifier has its own DSP budget (§7) |
| Feature precision | "Q8.8" (summary) vs. int8 (§6) | Signed 8-bit integer features and weights (`int8`); 32-bit accumulator |
| Mid price | `(b+a)/2` (real) | Integer mid `(bid+ask)>>1` everywhere — hardware, golden model, and labeler |
| Trade-print `side` | `0xFF` not applicable | For `msg_type=0x02`, `side` = aggressor side (feeds feature F6) |
| Classifier RTL | Hand-written `linear_classifier.sv` | hls4ml-generated IP (`Dense(8→1)`) wrapped in Verilog; threshold/hysteresis in hand RTL |
| Ethernet MAC | Assumed hand-written `eth_mac_tx`/`eth_mac_rx`, shape undecided | Reused from ALINX's AX7035B reference tree (`rtl/vendor/alinx_mac/`); boundary is a byte-push TX FIFO + whole-frame RX RAM, not AXI4-Stream or GMII — see `docs/design_decisions.md` D1 |
| System clock | Implicitly "125 MHz, source unspecified" | The MAC's recovered RGMII RX clock (`gmii_rx_clk`) *is* the single system clock; no separate CDC at the MAC boundary — D2 |
| `LINK_MODE` at bring-up | Raw Ethernet assumed lower-risk default | UDP (`LINK_MODE=1`) is the bring-up default; raw EtherType mode deferred (the reused MAC only dispatches ARP/IPv4/UDP) — D3 |
| PHY management | Assumed reusable as-is | Hand-written `mdio_ctrl.v` replaces ALINX's borrowed MIIM block (license incompatibility + a PHY-address bug) — D4 |
| Ethernet PHY identity | Micrel KSZ9031RNX (stated everywhere, incl. the board's own schematic) | JLSemi JL2121(D) — the schematic and every ALINX doc are wrong for the physically populated chip; corrected 2026-09-01 after re-reading `docs/refs/AX7035B_pinout_notes.md` (which already carries this correction from unrelated bring-up work) — D4 |

---

## 1. Problem Statement

### 1.1 The situation

An exchange broadcasts a stream of small binary messages describing price and size changes. A trading firm receives it, decides whether a change creates an opportunity, and — if it does — sends an order back. Everyone receives the broadcast at roughly the same instant, so the firms that profit are those whose reaction arrives first. The elapsed time between "the last bit of a market-data message arrives" and "the first bit of the resulting order leaves" is **tick-to-trade latency**, the single most valuable engineering quantity in the system.

### 1.2 Why hardware

A CPU path (NIC → driver → kernel → socket → scheduler → user code) costs variable time: a few microseconds on average, occasionally fifty. Two properties matter and are frequently confused:

- **Latency** — how long the reaction takes.
- **Determinism** — how tightly that duration is bounded.

A strategy sized around a 2 µs reaction that occasionally takes 50 µs is periodically and unpredictably wrong, and those occasions correlate with the busy moments when the opportunity existed. Determinism is often worth more than raw speed. An FPGA turns the task into a fixed physical path: bytes enter a pipeline and propagate through decode, book update, feature extraction, ML inference, signal, and risk — an assembly line where each stage works on a different message simultaneously. The cycle count from input to output is a property of the circuit, not of what else is running.

### 1.3 What is being built

A pipelined Artix-7 datapath that:

1. Receives a synthetic market-data feed over Gigabit Ethernet.
2. Parses frames, filters to watched symbols, maintains top-of-book state.
3. Extracts eight fixed-point features from the book (and a small amount of history).
4. Runs a **quantized classifier** (hls4ml-generated) that estimates short-horizon adverse-selection risk.
5. Feeds that risk as an additional, non-bypassable **risk gate** (`0x09`) in the same fast path as the deterministic signal.
6. Evaluates a fixed trading rule, passes the order intent through all risk gates, and emits a simulated order.
7. Measures its own tick-to-trade latency in a hardware histogram.

### 1.4 The role of ML in this design

The ML model does **not** replace the trading rule. It is a *risk signal*: it estimates whether a prospective passive quote is likely to be adversely selected in the near term, and that estimate gates the order. This keeps a clean separation, stated once and enforced everywhere:

> **The ML model may recommend blocking an order; deterministic hard logic decides whether the order is permitted.**

The model can never override the kill switch, position limits, size limits, price band, staleness, or sequence-gap checks. This is not a compromise — it is how production systems actually use learned models on the edge of a fast path: as one input to a rule that stays explainable and testable.

### 1.5 What is deliberately excluded

A **simulated** trading system: never connects to a real exchange, never carries real orders, never handles money. No production exchange protocol, no full TCP/IP stack, no multi-level order book in v1. The "exchange" is a Python program on a laptop. See §14 for the full out-of-scope list.

### 1.6 Success criteria

The project succeeds if all of the following are demonstrated and documented:

1. Processes back-to-back market-data messages at Gigabit line rate without dropping or reordering, verified over ≥ 1,000,000 messages.
2. Tick-to-trade latency, measured in hardware, is **fixed** — a single occupied histogram bucket for the accepting path, max == min.
3. Every risk gate — including the ML gate `0x09` — is individually demonstrated blocking (or reducing) an order that would otherwise have been sent, with a counter recording each rejection and reason.
4. The full RTL output (orders **and** ML score `z` and `adverse_risk`) matches a bit-exact Python golden model on every message of a randomized soak test.
5. The hls4ml IP output (`z`) matches the Python fixed-point golden model bit-exactly for every regression vector.
6. Design meets timing at 125 MHz on the target part with WNS > 0; utilization and timing reports published.
7. A person unfamiliar with the project can clone the repo, run one command, and reproduce the simulation results.

### 1.7 One-sentence version

> A pipelined Artix-7 datapath that receives a Gigabit-Ethernet market-data feed, maintains top-of-book state, extracts fixed-point features, runs a quantized hls4ml-generated adverse-selection classifier, gates the order intent through deterministic risk checks plus the ML verdict, and emits a simulated order — at a measured, fixed tick-to-trade latency, verified against a golden model.

---

## 2. Domain Glossary

| Term | Meaning in this project |
| :-- | :-- |
| **Instrument / symbol** | A tradable thing, identified by an 8-bit `symbol_id` (not a text ticker). |
| **Bid / Ask** | Best price someone will pay / accept. |
| **Top of book (TOB)** | Best bid and ask with sizes. |
| **Spread** | `ask − bid`, in ticks. Always ≥ 0 in a healthy market. |
| **Mid** | `(bid + ask) >> 1` — integer floor, defined identically in hardware, golden model, and labeler. |
| **Tick** | Smallest legal price increment. All prices are integers counting ticks. |
| **Crossed / locked book** | Bid ≥ ask. Crossed is impossible in a consistent market; locked (bid == ask) is non-tradable. Both suppress trading. |
| **Imbalance** | Comparison of resting bid size vs. ask size. |
| **Signal** | The fixed spread+imbalance rule that turns market state into an order intent (§6.6). |
| **Order intent** | A proposed order that has not yet passed risk checks. |
| **Pre-trade risk** | Hard, non-bypassable checks applied to every order intent. |
| **Kill switch** | A single input that immediately and latchingly blocks all outbound orders. |
| **Position / inventory** | Net quantity held; long positive, short negative. |
| **Adverse selection** | Being filled just before the price moves against you. |
| **Adverse-selection risk (ML output)** | The classifier's 1-bit estimate that a quote is likely to be adversely selected within horizon `H`. |
| **Feature** | One of eight fixed-point inputs to the classifier (§5.3). |
| **Score `z`** | Raw classifier output: `b + Σ w_i x_i`. |
| **Threshold / hysteresis** | `z ≥ T_high` sets adverse; `z ≤ T_low` clears it; between them the state is held. |
| **Tick-to-trade** | Elapsed time from arrival of the triggering message to departure of the resulting order. |
| **Sequence number** | A counter on every message so the receiver can detect loss. |
| **Line rate** | Maximum sustained message rate the link can carry (Gigabit Ethernet here). |
| **Backpressure** | A downstream block telling an upstream block to pause. The datapath is built so it never needs to (§7.4). |
| **Horizon `H`** | Number of future market-data events over which the adverse-selection label is defined (§5.2). |
| **Window `W`** | Number of recent events over which features F5/F7 are computed (§5.3). |

---

## 3. System Architecture

### 3.1 Block diagram

```text
   ┌──────────────────────────────────────────────────────────────┐
   │  HOST PC (Python)                                            │
   │  feed_gen.py  ──► synthetic market data (UDP)                │
   │  order_rx.py  ◄── simulated orders + stats (UDP)             │
   │  golden_model.py ── bit-exact reference (datapath + ML)      │
   │  train/  ── Keras model, quantization, hls4ml export         │
   └────────────────────────┬─────────────────────────────────────┘
                            │ 1000BASE-T
                    ┌───────▼────────┐
                    │  JL2121(D)     │  PHY
                    └───────┬────────┘
                            │ RGMII (4-bit DDR @125 MHz)
   ═════════════════════════▼══════════════════════════════════════
   FPGA — XC7A35T                              all @ 125 MHz, 8-bit
   ┌────────────────────────────────────────────────────────────┐
   │ [A] rgmii_to_gmii        DDR ↔ SDR conversion              │
   │ [B] eth_mac_rx           preamble/SFD strip, FCS check     │  ← existing MAC
   │ [C] frame_classifier     EtherType / IPv4 / UDP port match │
   │ [D] md_parser            byte-serial → structured message  │  ═ TIMESTAMP IN
   │ [E] symbol_filter        4-entry symbol CAM                │
   │ [F] seq_monitor          gap detection, staleness          │
   │ [G] tob_engine           best bid/ask registers per symbol │
   │      ├──► [G2] feature_extractor   F0–F7 from book+history │
   │      │        [G3] feature_normalizer  offset+shift→int8   │
   │      │        [P]  ml_classifier (hls4ml IP, Dense 8→1)    │
   │      │        [Q]  ml_policy        hysteresis → adverse   │
   │      └───────────────────────────────┐                     │
   │ [H] signal_engine        spread + imbalance rule           │
   │      │                     │                               │
   │      │              [ALIGN] delay to match ML path         │
   │      │                     │                               │
   │ [I] risk_engine          9 gates (incl. 0x09 ML)          │
   │ [J] order_builder        order record → frame              │  ═ TIMESTAMP OUT
   │ [K] eth_mac_tx           FCS append, IFG                   │  ← existing MAC
   │ ────────────────────────────────────────────────────────── │
   │ [L] latency_histogram    BRAM, 64 buckets                  │  slow path
   │ [M] csr_block            config + counters, UDP-addressed  │
   │ [N] stats_reporter       periodic stats frame emitter      │
   │ [O] debug_uart           fallback ingress + status dump    │
   └────────────────────────────────────────────────────────────┘
        │                              │
    KEY[0] kill switch            LED[3:0] status
```

### 3.2 The two convergent paths

There are two parallel datapaths after the book, and they converge at the risk engine:

**Signal path (fast):** `tob_engine → signal_engine → [ALIGN] → risk_engine`. The deterministic spread+imbalance rule produces an order intent in ~2 cycles.

**ML path (slower, fixed):** `tob_engine → feature_extractor → feature_normalizer → ml_classifier (hls4ml IP) → ml_policy → risk_engine`. This produces the 1-bit `adverse_risk` in ~7–10 cycles.

Because the ML path is deeper than the signal path, the order intent is delayed through a **fixed-depth alignment shift register** (`[ALIGN]`) whose depth equals the ML-path depth minus the signal-path depth. The ML verdict and the order intent arrive at the risk engine **in the same cycle**, every cycle, by construction. This is the single most important structural decision in the merged design: it lets ML sit in the critical path as a gate *without* making the tick-to-trade latency data-dependent. The alignment depth is a compile-time constant, and any mismatch is a race condition, not a tuning issue.

### 3.3 Partitioning rationale

- **Fast path (C → J, plus G2/G3/P/Q):** fully pipelined, no stalls, no arbitration, no dynamic memory, no state machine with variable cycle count. Latency is a synthesis-time constant.
- **Slow path (L, M, N, O):** configuration, statistics, reporting. Forbidden from asserting backpressure onto the fast path.
- **Control plane (M, kill switch):** writes registers the fast path reads combinationally. Config changes take effect on the next message; no handshake.

### 3.4 The hls4ml block in context

`[P] ml_classifier` is not hand-written Verilog. It is a Vitis HLS IP core generated by hls4ml from a Keras model of a single linear layer (`Dense(8→1)`, no activation). The model weights and bias are baked into the IP at synthesis time. The IP is instantiated inside a thin Verilog wrapper (`ml_classifier_wrap.v`) that presents the 8 normalized features as a parallel 8×8-bit input and samples the 32-bit score `z` output.

`[Q] ml_policy` is hand-written Verilog: it applies the hysteresis threshold (`T_high`/`T_low`), produces the `adverse_risk` bit and the `risk_level` telemetry byte. Thresholds and normalization parameters are runtime-configurable registers; weights are baked (see §5.5).

Keeping the threshold and hysteresis *outside* the hls4ml IP is deliberate: the deterministic control logic stays in testable, easily-verified RTL, and the hls4ml model stays minimal (one `Dense` layer), which is the lowest-risk possible hls4ml integration.

### 3.5 The MAC in context

`[B] eth_mac_rx` / `[K] eth_mac_tx` are not hand-written. They are ALINX's own RTL from the AX7035B reference tree, vendored into `rtl/vendor/alinx_mac/` unmodified except for two new status-output ports (§17 Q2). The boundary it presents is neither AXI4-Stream nor raw GMII — a byte-push TX FIFO and a whole-frame-buffered RX RAM — so a new adapter, `rtl/eth_mac_if.v`, converts it to the byte-stream shape the rest of the datapath (`frame_classifier` onward) expects. The MAC's recovered RGMII RX clock, `gmii_rx_clk`, is the engine's single 125 MHz system clock (no separate CDC at this boundary — the vendor MAC ties its own TX clock to the same recovered clock). Full rationale, the exact port list, and what was deliberately *not* reused (PHY management — see `rtl/common/mdio_ctrl.v`) are in `docs/design_decisions.md` (D1–D5).

---

## 4. Feed and Wire Format

### 4.1 Link-layer modes

`LINK_MODE` parameter selects ingress framing.

**Mode 0 — Raw Ethernet (`LINK_MODE = 0`).** EtherType `0x88B5` (local-experimental). No IP/UDP/ARP; payload begins at byte 14. Host uses a raw socket. **Deferred, not the bring-up default** — see `docs/design_decisions.md` D3: the vendored MAC (D1) only dispatches ARP/IPv4/UDP, so a raw-EtherType frame would need a hand-modified vendor dispatch path. Sim-only for now (the Verilog testbench can drive whatever framing it likes) or a later v1.x addition if a real need shows up; FR-2 stays in the spec but does not gate S11.

**Mode 1 — UDP/IPv4 (`LINK_MODE = 1`), the bring-up default.** EtherType `0x0800`, IPv4 (version 4, IHL 5, no options — IHL ≠ 5 discarded), protocol 17, destination UDP port matched against `cfg_udp_port` (default 60000). IPv4 header checksum verified; UDP checksum not verified (optional under IPv4; verifying it would require buffering the whole datagram and destroy the latency property — a real, defensible trade-off, stated in the README). Hardware bring-up (S11) targets this mode from the start — reversed from this document's original raw-Ethernet-first lean once D1 fixed the MAC's actual boundary; see D3.

For Mode 1 the host sets a static ARP entry (no ARP responder in v1):

```bash
sudo arp -s 192.168.1.10 00:0a:35:01:02:03
```

### 4.2 Prices are integers

All prices are unsigned integers counting ticks. `$100.01` at a `$0.01` tick is `10001`. Integer price comparison costs one LUT level and is exact; floating-point is neither.

### 4.3 Market-data message format

Fixed width, 16 bytes, big-endian (network byte order). Fixed width means the parser never needs to locate the next message start before parsing the current one.

| Offset | Size | Field | Description |
| :-- | :-- | :-- | :-- |
| 0 | 1 | `msg_type` | `0x01` quote update, `0x02` trade print, `0x03` book clear, `0xFF` heartbeat |
| 1 | 1 | `symbol_id` | Instrument identifier, 0–255 |
| 2 | 1 | `side` | `0x00` bid/buy, `0x01` ask/sell. For `0x01` = side being updated; for `0x02` = **aggressor side** (feeds feature F6); for `0xFF` heartbeat = not applicable |
| 3 | 1 | `flags` | bit0 end-of-burst, bit1 snapshot, bits 7:2 reserved (must be 0) |
| 4 | 4 | `price` | Price in ticks, unsigned |
| 8 | 4 | `quantity` | Size, unsigned |
| 12 | 4 | `seq_num` | Monotonically increasing per feed, wraps at 2³² |

**Update semantics for v1: snapshot-replace per side.** A `0x01` message states the *current* best price/size for a side; it replaces stored value, not an incremental add/modify/cancel. (Real feeds are incremental; §14.1 lists the multi-level book as v2.) A `0x03` clears the symbol to invalid. This keeps book update to one cycle.

### 4.4 Packing

One frame carries 1–88 messages (88 × 16 = 1408 bytes). Messages packed back-to-back, no padding. A payload not a multiple of 16 bytes is discarded whole (`err_frame_len`) and the parser resets. Multiple messages per frame is what forces the parser to be a streaming design.

### 4.5 Order output message format

Fixed 16 bytes, big-endian, one order per frame in v1.

| Offset | Size | Field | Description |
| :-- | :-- | :-- | :-- |
| 0 | 1 | `msg_type` | `0x10` new order, `0x11` risk reject (diagnostic), `0x12` stats |
| 1 | 1 | `symbol_id` | Instrument |
| 2 | 1 | `side` | `0x00` buy, `0x01` sell |
| 3 | 1 | `reject_reason` | `0x00` accepted; otherwise gate ID from §8.2 |
| 4 | 4 | `price` | Limit price in ticks |
| 8 | 4 | `quantity` | Order size |
| 12 | 2 | `trigger_seq` | Low 16 bits of the sequence number that caused this order |
| 14 | 2 | `latency_cyc` | Measured tick-to-trade latency in 125 MHz cycles |

Emitting `latency_cyc` inside the order means the host's capture is simultaneously a latency log.

---

## 5. The Machine-Learning Model

### 5.1 Objective and scope

Classify whether a prospective passive quote has elevated short-horizon adverse-selection risk. Outputs (one per valid feature vector):

```text
score_raw       z = b + Σ w_i x_i          (signed 32-bit)
risk_level      0–255 confidence-style byte (telemetry only)
adverse_risk    1-bit, hysteresis-thresholded
```

The model is trained and quantized in Python, exported through hls4ml, and synthesized to the Artix-7. It never routes to a real exchange; it is a demonstration of the *inference path*, not a claim about real market microstructure. Training on the FPGA is out of scope.

### 5.2 Label definition

For a quote decision at event `t`, mid price `m_t = (b_t + a_t) >> 1` (integer). For a candidate **buy** quote, label adverse if the mid falls by ≥ 1 tick within horizon `H` future events:

```text
y_buy,t  = 1  if  m_{t+H} − m_t ≤ −1   else 0
y_sell,t = 1  if  m_{t+H} − m_t ≥ +1   else 0
```

`H` is a fixed number of subsequent market-data events (20, 50, or 100), not wall-clock time — event horizons are reproducible in simulation.

**Important limitation (state it publicly):** this is a *proxy* label. A production adverse-selection model conditions on actual fills, queue position, and depth. Without real fill data, "adverse selection" here means "mid moved ≥ 1 tick against the quoted side within H events." The project is honest about this in the README and any write-up.

### 5.3 Feature specification

Exactly eight features. All computed with integer/fixed-point arithmetic so the Python reference matches hardware bit-for-bit.

| ID | Feature | Definition | Pre-normalization representation |
| :-- | :-- | :-- | :-- |
| F0 | Spread | `a_t − b_t` | unsigned, ticks |
| F1 | Mid-price delta | `m_t − m_{t−1}` | signed, ticks |
| F2 | Book imbalance | `q_b − q_a` (v1, no division) | signed |
| F3 | Bid-size change | `q_{b,t} − q_{b,t−1}` | signed |
| F4 | Ask-size change | `q_{a,t} − q_{a,t−1}` | signed |
| F5 | Update rate | updates observed in the last `W` events | unsigned, clipped |
| F6 | Last trade direction | buy = +1, sell = −1, none = 0 | signed |
| F7 | Short-term volatility proxy | sum of \|mid deltas\| over last `W` events | unsigned, clipped |

Feature-state requirements (new hardware state, §6.4): per-symbol `prev_bid`, `prev_ask` (and derived `prev_mid`), a `W`-wide update-window shift register + popcount (F5), a `W`-deep delay line of |mid deltas| with a running sum (F7), and `last_trade_side` (F6). With `NUM_SYMBOLS=4` and `W=16`, this is a few dozen registers per symbol — registers, not BRAM.

Imbalance (F2) is staged: v1 = raw difference `q_b − q_a`; v2 = difference with a power-of-two shift; v3 = normalized `(q_b−q_a)/(q_b+q_a+1)` via reciprocal LUT. Start at v1. This F2 is **independent** of the signal engine's barrel-shift imbalance rule (§6.6) — different consumers, both kept.

### 5.4 Model specification

**v1 — linear classifier (logistic regression without the sigmoid):**

```text
z = b + Σ_{i=0..7} w_i x_i
adverse_risk = 1  if  z ≥ T_high
```

The sigmoid is omitted because it is monotonic: comparing `z` to a threshold gives the identical class decision as comparing a probability to a probability threshold. The model is a single Keras `Dense(1, use_bias=True, activation='linear')`.

**Parameter formats:**

| Quantity | Format | Notes |
| :-- | :-- | :-- |
| Normalized feature `x_i` | signed 8-bit (`int8`, −128…127) | after §5.3 normalization |
| Weight `w_i` | signed 8-bit | quantized offline |
| Product `w_i·x_i` | signed 16-bit | exact |
| Bias `b` | signed 32-bit | aligned to accumulator |
| Accumulator `z` | signed 32-bit | 8 products + bias; overflow impossible at this width |
| Threshold `T_high`, `T_low` | signed 32-bit | runtime registers |
| `risk_level` | unsigned 8-bit | `saturate((z + offset) >> shift)` |

**v2 — small MLP (after v1 is verified):** `x → Dense(8, ReLU/clamp) → Dense(1) → threshold`, 4–8-bit weights/activations, trained with quantization awareness. Resource note: fully-parallel 8×8×1 ≈ 72 MACs vs. the part's 90 DSPs — see §7.3.

### 5.5 Normalization and the hardware contract

Normalization maps each raw feature to a bounded signed integer **before** the classifier, using powers-of-two only (no division hardware):

```text
x_i = saturate_{[-128,127]}( (raw_i − offset_i) >>> shift_i )
```

Each `offset_i` and `shift_i` is recorded in a machine-readable model-parameter file (`model/model_config.json`) — part of the model's hardware contract. In v1 these are runtime-configurable registers (see §9) so they can be tuned without re-synthesis; they may be baked in later once frozen.

**Division of labor at the boundary:**

| Piece | Owner | Artifact |
| :-- | :-- | :-- |
| Feature computation + normalization | FPGA (hand RTL) | `feature_extractor.v`, `feature_normalizer.v` |
| `z = b + Σ w_i x_i` | ML (hls4ml) | Keras model → hls4ml → Vitis HLS IP |
| Threshold + hysteresis + `adverse_risk` | FPGA (hand RTL) | `ml_policy.v` |

### 5.6 hls4ml flow specification

The ML engineer's contract is:

1. **Train** a `Dense(8→1, linear)` model in Keras (TensorFlow).
2. **Quantize** weights to `int8` (QAT if needed for v2), freeze features/preprocessing, export `int8` weights + `int32` bias + `int8` normalization parameters.
3. **Convert** with hls4ml:
   - Backend: `Vitis`.
   - Part: `xc7a35tfgg484-2` (confirm exact Vivado part string in S0; the device is `XC7A35T-2FGG484I`).
   - `IOType: io_parallel` (features arrive as 8 parallel bytes; the model is fully unrolled).
   - Precision: `ap_fixed<8,8>` (int8) for features/weights, `ap_fixed<32,32>` accumulator, `ReuseFactor: 1`.
   - Verify the generated top function is stall-free and fixed-latency.
4. **Verify bit-exactness:** run `hls_model.trace(x)` / `hls_model.predict(x)` (C simulation) on the exported golden vectors and require bit-exact agreement with the Python fixed-point golden model (`sim/ml_golden.py`). This is §11's ML-golden gate.
5. **Export** the IP (`Vitis HLS → export RTL/IP`), hand off `.xo`/RTL + the interface description to the FPGA owner for integration into `ml_classifier_wrap.v`.

The FPGA engineer's contract is:

6. Wrap the IP in `ml_classifier_wrap.v`: 8×8-bit feature input, `z` output, `ap_ctrl_none` (no handshake) for lowest latency; register the output.
7. Verify the combined wrapper + IP against the same golden vectors in simulation.

---

## 6. Functional Requirements

Each requirement is numbered, independently testable, and mapped to tests in §11.

### 6.1 Ingress and framing

| ID | Requirement |
| :-- | :-- |
| FR-1 | Receive frames from the GMII interface of the existing MAC; process only frames whose FCS passed. FCS-error frames discarded silently, `err_fcs` incremented. |
| FR-2 | `LINK_MODE=0`: accept EtherType `0x88B5`; byte 14 onward is payload. |
| FR-3 | `LINK_MODE=1`: accept EtherType `0x0800`, IHL=5, valid IPv4 header checksum, protocol 17, UDP port = `cfg_udp_port`. Any failure discards and increments the matching counter. |
| FR-4 | Accept payloads of 1–88 packed 16-byte messages; parse every message. |
| FR-5 | Payload length not a multiple of 16 → discard frame, increment `err_frame_len`, parser returns to idle before next frame start. |
| FR-6 | Accept frames arriving at minimum Ethernet inter-frame gap without loss. |

### 6.2 Filtering and validation

| ID | Requirement |
| :-- | :-- |
| FR-7 | Maintain configurable `NUM_SYMBOLS` (default 4) watched `symbol_id`s; forward only matching messages. Non-matching → `cnt_filtered`, no other effect. |
| FR-8 | Discard messages with `msg_type` outside the defined set; increment `err_msg_type`. |
| FR-9 | Discard messages with reserved `flags` bits set; increment `err_flags`. |
| FR-10 | Track expected next `seq_num` per feed. Larger than expected → increment `cnt_seq_gap` by the gap, set sticky `seq_gap`, assert stale. |
| FR-11 | `seq_num` less than expected (dup/reorder) → drop message, increment `cnt_seq_dup`, no book modification. |
| FR-12 | `seq_gap` clears only on a `flags.snapshot=1` message or explicit CSR clear. |

### 6.3 Top-of-book state

| ID | Requirement |
| :-- | :-- |
| FR-13 | Per watched symbol hold `bid_price`, `bid_qty`, `ask_price`, `ask_qty`, per-side `valid` bits. |
| FR-14 | `0x01` message replaces price+quantity of the addressed side, sets that side's `valid`, in one cycle. |
| FR-15 | `0x01` with `quantity=0` clears that side's `valid` without altering stored price. |
| FR-16 | `0x03` clears both `valid` bits for the symbol. |
| FR-17 | Detect crossed book (`bid_price ≥ ask_price` with both valid), set `crossed` status, increment `cnt_crossed`. |
| FR-18 | Book state initializes to invalid on reset; no stale value readable after reset. |
| FR-19 | `0x02` (trade) and `0xFF` (heartbeat) do not modify book state. Heartbeat refreshes the staleness timer; trade increments `cnt_trades`. |

### 6.4 Feature extraction (new)

| ID | Requirement |
| :-- | :-- |
| FR-20 | After each book update, compute features F0–F7 (§5.3) for the addressed symbol. |
| FR-21 | Maintain per-symbol history: `prev_bid`, `prev_ask`, derived `prev_mid`, `W`-event update window (F5), `W`-deep \|mid-delta\| running sum (F7), and `last_trade_side` (F6). |
| FR-22 | Normalize each feature to signed 8-bit via `saturate((raw − offset_i) >> shift_i)`. Saturate, never wrap. |
| FR-23 | Feature extraction and normalization use only add/subtract/shift/compare. No multiplier or division on this stage. |
| FR-24 | Features are computed only for watched symbols; filtered messages produce no feature update. |
| FR-25 | A `0x02` trade print updates `last_trade_side` (aggressor side from `side`) and the update window, without changing book price/qty state. |
| FR-26 | When a side is invalid, cross/ locked, or a sequence gap is set, the classifier input is forced to a safe state and `adverse_risk` is forced to 1 (§6.5 FR-31). |

### 6.5 ML classifier (new)

| ID | Requirement |
| :-- | :-- |
| FR-27 | Compute `z = b + Σ_{i=0..7} w_i·x_i` with exact `int8 × int8 → int32` accumulation, no overflow at 32 bits. |
| FR-28 | Set `adverse_risk = 1` when `z ≥ T_high`; clear to 0 when `z ≤ T_low`; hold previous value when `T_low < z < T_high` (hysteresis). |
| FR-29 | `T_high > T_low`, both runtime-configurable; hysteresis prevents oscillation near the threshold. |
| FR-30 | The ML path (`feature_extractor → normalizer → classifier → policy`) is a fixed-depth pipeline with no stalls and data-independent latency. |
| FR-31 | On invalid/crossed/locked book, sequence gap, or staleness, `adverse_risk` is forced to 1 regardless of `z` (fail-safe). |
| FR-32 | Weights and bias are baked at synthesis (hls4ml); thresholds, normalization offsets/shifts, and window `W` are runtime configurable. |
| FR-33 | Produce `score_raw` (32-bit) and `risk_level` (8-bit) for telemetry in addition to `adverse_risk`. |
| FR-34 | `z` and `adverse_risk` match the Python fixed-point golden model bit-exactly for every regression vector. |

### 6.6 Signal

| ID | Requirement |
| :-- | :-- |
| FR-35 | After each book-modifying update, evaluate the buy rule: both sides valid, not crossed, `spread ≥ cfg_min_spread`, and `bid_qty > (ask_qty << cfg_imb_shift)`. |
| FR-36 | Evaluate the mirrored sell rule: `ask_qty > (bid_qty << cfg_imb_shift)`. |
| FR-37 | Both rules satisfied simultaneously is impossible by construction; if ever detected, no order and `err_signal_conflict` increments. |
| FR-38 | Buy → order intent to buy `cfg_order_qty` at `ask_price`; sell → sell `cfg_order_qty` at `bid_price`. |
| FR-39 | Signal uses only shifts, comparisons, subtraction. No multipliers, no DSP on the signal path. |
| FR-40 | Signal evaluated on every book-modifying message, not on a timer; need not have changed the book's value. |

### 6.7 Risk

| ID | Requirement |
| :-- | :-- |
| FR-41 | Every order intent passes all gates in §8.2 before any order byte is emitted. No path emits an order bypassing the risk engine. |
| FR-42 | All gates evaluated in parallel in a single cycle. |
| FR-43 | A blocked order increments its gate's counter. Multiple gates firing → lowest-numbered gate is `reject_reason`, and every triggered gate's counter increments. |
| FR-44 | `cfg_reject_report=1` emits a `0x11` diagnostic frame for blocked orders; default 0 (off) so diagnostics cannot influence measured behavior. |
| FR-45 | Maintain signed net position per symbol, updated on each accepted order under the fill model (§8.3). |
| FR-46 | Kill switch blocks all outbound orders within one cycle of input registration, and latches. Deassertion alone does not resume; explicit CSR clear required. |
| FR-47 | Kill switch readable as a status bit and drives a dedicated LED. |
| FR-48 | Gate `0x09` (ML): when `adverse_risk=1`, the order is blocked (default) or reduced in size per `cfg_ml_action` (§8.2). The ML verdict is advisory to the risk engine, not a substitute for gates `0x01`–`0x08`. |

### 6.8 Egress

| ID | Requirement |
| :-- | :-- |
| FR-49 | Accepted order encoded per §4.5 and transmitted as a single frame with correct framing for the active `LINK_MODE` (incl. IPv4 checksum in Mode 1). |
| FR-50 | Order emission begins at a fixed cycle offset from the ingress timestamp for every accepting message, independent of content, symbol, or history. |
| FR-51 | Orders are not reordered relative to their triggering messages. |
| FR-52 | A market-data message arriving during order transmission is still parsed and applied; only transmission of a subsequent order may queue (§7.4). |

### 6.9 Measurement and control

| ID | Requirement |
| :-- | :-- |
| FR-53 | A free-running 32-bit cycle counter at 125 MHz; captured at ingress timestamp point (last byte of a message entering the parser) and carried with the message. |
| FR-54 | At egress timestamp point (first byte handed to MAC TX), compute latency and record in a 64-bucket BRAM histogram. |
| FR-55 | Maintain `lat_min`, `lat_max`, `lat_last` registers. |
| FR-56 | Counters and histogram readable via stats frames every `cfg_stats_period` cycles and on-demand CSR read. |
| FR-57 | Reading statistics never stalls, delays, or affects the fast path. |
| FR-58 | All configuration values in §9 writable via CSR and take effect on the next message boundary. |
| FR-59 | UART fallback ingress accepting the same 16-byte format for bring-up without Ethernet. Latency is flagged not-meaningful in this mode. |

---

## 7. Non-Functional Requirements

### 7.1 Latency

| ID | Requirement |
| :-- | :-- |
| NFR-1 | Tick-to-trade latency from ingress to egress timestamp point is a fixed constant for every accepting message. Target ≤ 22 cycles (176 ns @ 125 MHz); exact value is measured and published (§12.1). |
| NFR-2 | The measured histogram shows exactly one occupied bucket for the accepting path across the full soak. A second bucket is a functional bug, not a performance result. |
| NFR-3 | Wire-to-wire latency (including MAC RX/TX) measured separately and reported as a budget table (§12.1). |

Design-target latency budget — the **critical path runs through the ML branch** (the deeper path). The signal branch runs in parallel and is hidden by the alignment register, so it adds nothing to the total. Fill actual values in §12.1.

| Stage | Cycles (target) | Notes |
| :-- | --: | :-- |
| Parser ingress → structured message | 1 | timestamp at last byte |
| Symbol filter | 1 | CAM compare |
| Book update | 1 | register write |
| Feature extraction | 1 | F0–F7, register history |
| Feature normalization | 1 | shift/subtract/saturate |
| ML classifier (hls4ml Dense) | 2–3 | parallel MAC + adder tree |
| ML policy (hysteresis) | 1 | threshold compare |
| Risk (all 9 gates, incl. ML verdict) | 1 | parallel |
| Order builder → first byte | 1 | serialize |
| **Engine total (tick-to-trade)** | **~10–11 (target ≤ 22)** | single fixed value |

The **signal branch** (`book → signal → order intent`, 1 cycle) runs in parallel with the ML branch and is delayed through a fixed-depth alignment register so its order intent arrives at the risk engine in the same cycle as `adverse_risk`. Alignment depth ≈ 4–5 cycles = (ML-branch depth) − (signal-branch depth), a compile-time constant (NFR-14).

### 7.2 Throughput

| ID | Requirement |
| :-- | :-- |
| NFR-4 | Sustain one 16-byte message every 16 cycles indefinitely (the max a 1 Gbps 8-bit/cycle link delivers) with zero drops. |
| NFR-5 | Internal pipeline accepts one message per cycle so widening the ingress later requires no core change. |

### 7.3 Timing and resources

| ID | Requirement |
| :-- | :-- |
| NFR-6 | Meet timing at 125 MHz on `XC7A35T-2FGG484I` with WNS > 0 after place-and-route. |
| NFR-7 | Engine logic **excluding the ML classifier** consumes ≤15% LUTs (≈3,100 of 20,800), ≤10% FFs, ≤8 BRAM36 of 50, and **0 DSP**. The ML classifier consumes ≤8 DSP48 (v1) and ≤16 DSP48 (v2 via reuse/LUT multipliers). Total DSP ≤ 80% of the part's 90. |
| NFR-8 | Single 125 MHz clock domain for the engine; any CDC (UART, buttons) confined to the slow path with two-flop synchronizers, documented. |

### 7.4 Design constraints

| ID | Requirement |
| :-- | :-- |
| NFR-9 | Hand-written RTL in `rtl/` is Verilog-2001, synthesizable subset. The hls4ml-generated IP is the sole exception (it is HLS-generated C++/RTL). |
| NFR-10 | No inferred latches, no combinational feedback loops, no asynchronous resets except the synchronized top-level power-on reset. |
| NFR-11 | No dynamic memory allocation, no variable-iteration loops, no arbitration on the fast path. Every fast-path structure has fixed depth at elaboration. |
| NFR-12 | The fast path contains no FIFO whose fullness varies with message content. |
| NFR-13 | All magic numbers are `parameter`/`localparam`; configurable behavior is register-driven, not recompiled. |
| NFR-14 | The ML path is stall-free and fixed-latency; its latency is data-independent and verified (§11, T31/T34). |

### 7.5 On backpressure

The fast path is stall-free by construction. The parser consumes 8 bits/cycle (the MAC delivers 8 bits/cycle); book update, feature extraction, ML, signal, and risk are fixed-depth stages with registered outputs. No stage consumes slower than its predecessor produces.

The one place queueing can occur is order transmission: an order frame occupies TX for ~84 cycles, and the signal can fire again in that window. The design uses a **2-deep order output register, not a deep FIFO**, with an explicit overflow policy: a third order while two are pending is dropped, `cnt_order_overflow` increments. Dropping is correct: a queued stale order trades on information known to be outdated, and an unbounded queue would make latency history-dependent, violating NFR-1.

---

## 8. Risk Engine Specification

### 8.1 Design principle

The risk gates are the last stage of the fast path and run at the same speed as everything else. Any implementation where risk lives on a slower path, can be disabled by configuration, or bypassed by a code path, fails FR-41. This is the requirement to defend most carefully during implementation.

### 8.2 Gates

| ID | Gate | Condition to block | Rationale |
| :-- | :-- | :-- | :-- |
| `0x01` | Kill switch | `kill_latched` | Operator/automated halt; overrides everything. |
| `0x02` | Max order size | `order_qty > cfg_max_order_qty` | No unbounded order from a fat-finger or logic error. |
| `0x03` | Max position | `\|position ± order_qty\| > cfg_max_position` | Bounds total exposure. |
| `0x04` | Price band | `\|order_price − mid\| > cfg_price_band` | Protects against acting on corrupt price data. |
| `0x05` | Stale data | `cycles_since_update > cfg_max_age` | Do not trade on a quiet/guessed book. |
| `0x06` | Sequence gap | `seq_gap` sticky | Messages missed; book unreliable until resync. |
| `0x07` | Crossed/locked book | `bid_price ≥ ask_price` | Physically impossible state → corrupt data. |
| `0x08` | Order rate throttle | token bucket empty | Bounds message rate and damage from a runaway signal. |
| `0x09` | **Adverse selection (ML)** | `adverse_risk == 1` | ML estimates the quote is likely adversely selected within horizon `H`. |

Gate `0x09` behavior is selected by `cfg_ml_action`:

| `cfg_ml_action` | Effect when `adverse_risk=1` |
| :-- | :-- |
| `0x0` | Block the order (default) |
| `0x1` | Reduce order size by `cfg_ml_reduce_shift` (order_qty >> shift, floor ≥ 1) |

Priority for `reject_reason` is by gate number (lowest wins). ML is `0x09` — the highest number, so deterministic hard gates always dominate the reported reason, while `cnt_rej_ml` still increments when ML fires alongside others.

### 8.3 Position and fill model

**v1: immediate full fill.** An accepted order is assumed to execute completely at its limit price on the cycle it is emitted; `position` updates by ±`order_qty`. This is optimistic and the README states it plainly. A probabilistic fill model (seeded PRNG shared with the golden model) is §14.4.

### 8.4 Token bucket throttle

A counter of permits; each order consumes one; permits replenish at a fixed rate to a ceiling. Parameters `cfg_token_max` (8) and `cfg_token_refill_cycles` (12500 = one per 100 µs).

---

## 9. Configuration Register Map

Accessed via CSR frames (`0x20` write, `0x21` read request, `0x22` read response). All registers 32-bit.

| Addr | Name | Default | Description |
| :-- | :-- | :-- | :-- |
| `0x00` | `CTRL` | `0x0` | bit0 engine enable, bit1 kill clear (self-clearing), bit2 counter clear, bit3 seq-gap clear, bit4 reject reporting |
| `0x04` | `STATUS` | — | bit0 kill latched, bit1 seq gap, bit2 crossed, bit3 stale, bit4 ML-adverse, bits 7:5 side-valid map |
| `0x08`–`0x14` | `SYMBOL_0..3` | `1,2,3,4` | Watched symbol IDs |
| `0x18` | `SYMBOL_EN` | `0xF` | Per-slot enable |
| `0x1C` | `MIN_SPREAD` | `2` | Min spread in ticks for signal |
| `0x20` | `IMB_SHIFT` | `1` | Imbalance shift, 0–3 |
| `0x24` | `ORDER_QTY` | `100` | Generated order size |
| `0x28` | `MAX_ORDER_QTY` | `500` | Gate `0x02` |
| `0x2C` | `MAX_POSITION` | `1000` | Gate `0x03`, symmetric |
| `0x30` | `PRICE_BAND` | `50` | Gate `0x04`, ticks |
| `0x34` | `MAX_AGE` | `1250000` | Gate `0x05`, cycles (10 ms) |
| `0x38` | `TOKEN_MAX` | `8` | Throttle ceiling |
| `0x3C` | `TOKEN_REFILL` | `12500` | Cycles per token |
| `0x40` | `UDP_PORT` | `60000` | Ingress UDP port, Mode 1 |
| `0x44` | `STATS_PERIOD` | `12500000` | Stats interval (100 ms) |
| `0x48` | `ML_TH_HIGH` | `0` | `T_high`, signed 32-bit |
| `0x4C` | `ML_TH_LOW` | `0` | `T_low`, signed 32-bit |
| `0x50` | `ML_CTRL` | `0x0` | bit0 `cfg_ml_action` (0 block / 1 reduce), bits 4:1 `cfg_ml_reduce_shift` (0–15), bit8 ML bypass (debug only, off by default) |
| `0x54` | `ML_SCORE_OFFSET` | `0` | `risk_level = (z + offset) >> shift` |
| `0x58` | `ML_SCORE_SHIFT` | `0` | Risk-level shift |
| `0x5C` | `ML_WINDOW` | `16` | Feature window `W` (4/8/16/32) |
| `0x60`–`0x7C` | `ML_OFFSET_0..7` | `0` | Normalization offsets for F0–F7 |
| `0x80`–`0x9C` | `ML_SHIFT_0..7` | `0` | Normalization shifts for F0–F7 |
| `0xA0`+ | Counters | — | Read-only block, §10 |

Weights and bias (`w_i`, `b`) are **not** in the register map — they are baked into the hls4ml IP at synthesis. Reloadable weights via AXI/CSR are an extension (§14.8).

---

## 10. Counter Set and Invariants

All counters 32-bit, saturating (not wrapping), clearable via `CTRL.bit2`. Saturating matters: a wrapped counter can read small after a large failure, exactly when the number must be trusted.

**Ingress:** `cnt_frames_rx`, `cnt_msgs_rx`, `cnt_msgs_filtered`, `cnt_msgs_accepted`
**Errors:** `err_fcs`, `err_ethertype`, `err_ip`, `err_udp_port`, `err_frame_len`, `err_msg_type`, `err_flags`, `err_signal_conflict`
**Feed health:** `cnt_seq_gap`, `cnt_seq_dup`, `cnt_crossed`, `cnt_book_clear`, `cnt_trades`, `cnt_heartbeats`
**Signal:** `cnt_signal_buy`, `cnt_signal_sell`
**ML:** `cnt_ml_events` (valid feature vectors processed), `cnt_ml_adverse` (`adverse_risk=1`), `cnt_ml_benign` (`adverse_risk=0`), `cnt_ml_safe_forced` (fail-safe forced adverse on invalid/stale/gap input), `cnt_rej_ml` (gate `0x09` blocked/reduced)
**Risk (one per gate):** `cnt_rej_kill`, `cnt_rej_size`, `cnt_rej_position`, `cnt_rej_band`, `cnt_rej_stale`, `cnt_rej_seqgap`, `cnt_rej_crossed`, `cnt_rej_throttle`, `cnt_rej_ml`
**Egress:** `cnt_orders_tx`, `cnt_order_overflow`
**Latency:** `lat_min`, `lat_max`, `lat_last`, 64-bucket histogram

**Invariants (asserted in the testbench):**

```text
cnt_msgs_rx = cnt_msgs_filtered + cnt_msgs_accepted + Σ(err_* message-level counters)
cnt_signal_buy + cnt_signal_sell = cnt_orders_tx + Σ(cnt_rej_*) + cnt_order_overflow
cnt_ml_events  = cnt_ml_adverse + cnt_ml_benign              // every ML event lands in exactly one bucket
cnt_rej_ml     ≤ cnt_ml_adverse                             // ML rejections ⊆ adverse flags
cnt_ml_safe_forced ≤ cnt_ml_adverse                         // fail-safe forced adverse ⊆ adverse flags
```

Counter conservation catches a silently-vanishing message as an immediate arithmetic mismatch.

---

## 11. Verification Plan

### 11.1 Golden models

Two Python golden models, both written **from this spec, not from the RTL**, and ideally before the RTL:

- `sim/golden_model.py` — the full datapath in integer arithmetic: consumes the stimulus, produces the expected order stream and final counters.
- `sim/ml_golden.py` — the fixed-point ML reference: `int8 × int8 → int32` accumulation, `saturate`, `>>` truncation semantics, threshold, hysteresis, and fail-safe forcing — matching the hls4ml arithmetic exactly.

A model derived by reading the RTL can only confirm the RTL does what the RTL does; it cannot catch a misreading of the spec.

### 11.2 Stimulus generation

`sim/feed_gen.py` produces live UDP traffic and offline hex files, with reproducible seeds (recorded in every results file):

- `--scenario normal` — well-formed random walk, both sides valid
- `--scenario sparse` — long gaps (staleness gate)
- `--scenario crossed` — injects crossed books
- `--scenario gaps` — drops/duplicates sequence numbers
- `--scenario malformed` — bad lengths/types/flags
- `--scenario burst` — line-rate back-to-back frames
- `--scenario trigger` — fires the signal at a known rate
- `--scenario adverse` — tuned to produce adverse-selection labels at a known rate (for ML tests)

### 11.3 Testbench structure

`tb/tb_top.v` — Verilog, file I/O (`$readmemh`, `$fscanf`), self-checking. Drives the GMII-side interface, captures the order stream and ML outputs, compares against both golden models byte-for-byte. Any mismatch prints message index, expected, actual, and book state, then fails; exits non-zero to gate CI.

### 11.4 Directed test list

| Test | Covers | Description |
| :-- | :-- | :-- |
| `T01_smoke` | FR-1,4,14 | One frame, one message, book updates |
| `T02_packed` | FR-4,6 | 88 messages in one frame, in order |
| `T03_back_to_back` | FR-6, NFR-4 | Min IFG for 10,000 frames, zero loss |
| `T04_filter` | FR-7 | Mixed symbols; only watched affect state |
| `T05_bad_length` | FR-5 | Payload 17/15/0 bytes; clean recovery |
| `T06_bad_type` | FR-8,9 | Undefined types, reserved flags |
| `T07_ipv4` | FR-3 | Mode 1: bad checksum, wrong port, IHL≠5, good frame |
| `T08_seq_gap` | FR-10,12 | Gap → gate `0x06` blocks; snapshot clears |
| `T09_seq_dup` | FR-11 | Dup/reorder; book unchanged |
| `T10_qty_zero` | FR-15 | Zero-quantity update invalidates side |
| `T11_book_clear` | FR-16 | Clear then repopulate |
| `T12_crossed` | FR-17, `0x07` | Crossed detected and blocks |
| `T13_signal_buy` | FR-35,38 | Exact threshold: at, below, above |
| `T14_signal_sell` | FR-36,38 | Mirror of T13 |
| `T15_gate_size` | `0x02` | Order size at/below/above limit |
| `T16_gate_position` | `0x03` | Walk position to limit ±1, both directions |
| `T17_gate_band` | `0x04` | Price at band edge and one tick out |
| `T18_gate_stale` | `0x05` | Silence past `MAX_AGE`, then fresh update |
| `T19_gate_throttle` | `0x08` | Burst empties bucket; verify refill |
| `T20_kill` | FR-46,47 | Assert mid-stream; latch; CSR clear required |
| `T21_multi_gate` | FR-43 | Two gates fire; reason priority + both counters |
| `T22_overflow` | §7.5 | Three orders inside one TX window |
| `T23_reset` | FR-18 | Reset mid-stream; no stale state |
| `T24_csr` | FR-58 | Write every register, read back, effect on next message |
| `T25_latency` | NFR-1,2 | Histogram has exactly one occupied bucket |
| `T26_soak` | all | 1,000,000 random messages, full output+counter comparison |
| `T27_feature_units` | FR-20,21 | Spread, deltas, imbalance, update rate, volatility, clipping |
| `T28_known_score` | FR-27,34 | Hand-computed `z` for known inputs |
| `T29_saturation` | FR-22 | Overrange features saturate, never wrap |
| `T30_threshold` | FR-28 | `z` just below/equal/above `T_high` |
| `T31_hysteresis` | FR-28,29 | No chatter around threshold; hold in band |
| `T32_gate_ml_block` | `0x09` | `adverse_risk=1` blocks; counter increments |
| `T33_gate_ml_reduce` | `0x09`, `ML_CTRL` | `cfg_ml_action=1` reduces size correctly |
| `T34_ml_failsafe` | FR-26,31 | Invalid/crossed/gap forces `adverse_risk=1` |
| `T35_ml_bit_exact` | FR-34 | hls4ml IP `z` == `ml_golden.py` for all golden vectors |
| `T36_align` | FR-50, NFR-14 | ML verdict and order intent arrive same cycle; no race |

### 11.5 Coverage goals (asserted by testbench at end of soak)

- Every FSM state reached; every risk gate (incl. `0x09`) rejected ≥1 order
- Both signal directions fired; every `msg_type` exercised; every symbol slot used
- Every error counter incremented; counter-conservation invariants hold at end of every test
- ML: both hysteresis transitions exercised; fail-safe forcing exercised; `risk_level` saturation exercised

### 11.6 Hardware validation

Simulation is necessary but not sufficient; §1.6 claims are about hardware.

1. **Loopback:** host sends a known 1,000-message file; orders + ML outputs compared to golden models; byte-exact required.
2. **Line-rate soak:** 10 min max-density traffic; `cnt_msgs_rx` equals host count exactly; `cnt_order_overflow` matches prediction.
3. **ILA capture** of the fast path: ingress/egress timestamps + `z`/`adverse_risk` on the same trigger.
4. **Oscilloscope** across RJ45 pins for wire-to-wire, with GPIO toggles at the timestamp points as reference.
5. **Kill switch** pressed physically mid-soak; orders cease, LED asserts.
6. **ML on-board check:** replay the golden vectors through the FPGA over UART/Ethernet; `z` and `adverse_risk` must match `ml_golden.py`.

---

## 12. Results to Publish

### 12.1 Latency table

| Metric | Cycles | ns @125 MHz |
| :-- | --: | --: |
| Parser ingress → book updated | | |
| Book → signal decision | | |
| Book → ML verdict (`adverse_risk`) | | |
| Signal → risk verdict | | |
| Risk → first order byte | | |
| **Engine total (tick-to-trade)** | | |
| MAC RX contribution | | |
| MAC TX contribution | | |
| **Wire-to-wire** | | |

Report min, median, p99, max for each. **p99 == max == min is the result being claimed.**

### 12.2 Utilization

LUT, FF, BRAM, DSP per module and total (post-implementation), as a percentage of the XC7A35T's 20,800 LUTs / 41,600 FFs / 50 BRAM36 / 90 DSPs. Report the classifier's DSP usage separately (NFR-7).

### 12.3 Timing

WNS, TNS, achieved Fmax, top five critical paths with a sentence each on what limits it. A critical path you can explain is worth more than a slack number you cannot.

### 12.4 ML quality (honest framing)

On the synthetic dataset, report precision/recall/F1 and ROC-AUC for the adverse-risk class, a confusion matrix, and an economic-proxy comparison (risky quotes avoided vs. benign quotes suppressed). State plainly that this is a synthetic proxy-label evaluation, not evidence of real market behavior.

### 12.5 Baselines (the "so what")

Compare, in one table, the same classifier expressed four ways:

1. Hand-tuned threshold rule (no learned weights)
2. Floating-point logistic regression (CPU)
3. Quantized logistic regression (CPU fixed-point)
4. hls4ml FPGA implementation (this project)

Metrics: latency (cycles), throughput (updates/s), resource use (LUT/FF/DSP/BRAM), and F1 on the held-out synthetic set. This table is the project's headline evidence.

---

## 13. Deliverables and Repository Layout

```
fpga-tick-to-trade-engine/
├── README.md                  # architecture, feed format, decision rule, risk table, reproduce, results
├── LICENSE                    # Apache-2.0
├── docs/
│   ├── master_spec.md         # this document
│   ├── block_diagram.svg
│   ├── latency_budget.md
│   ├── fixed_point_contract.md# int8 formats, truncation, saturation, normalization
│   ├── hls4ml_flow.md         # train→quantize→export→IP→wrap, version pins
│   └── design_decisions.md    # every "why not X" answered
├── rtl/
│   ├── tob_top.v
│   ├── eth_mac_if.v            # adapts vendor/alinx_mac's byte-push/RAM boundary to a byte-stream
│   ├── frame_classifier.v
│   ├── md_parser.v
│   ├── symbol_filter.v
│   ├── seq_monitor.v
│   ├── tob_engine.v
│   ├── feature_extractor.v
│   ├── feature_normalizer.v
│   ├── ml_classifier_wrap.v    # instantiates hls4ml IP
│   ├── ml_policy.v
│   ├── signal_engine.v
│   ├── risk_engine.v
│   ├── order_builder.v
│   ├── latency_histogram.v
│   ├── csr_block.v
│   ├── vendor/
│   │   └── alinx_mac/           # ALINX reference MAC, vendored per docs/design_decisions.md D1
│   └── common/                 # sync_2ff.v, counter_sat.v, mdio_ctrl.v, ...
├── hls4ml/                     # generated project (gitignored, rebuilt by script)
│   └── myproject_prj/          # Vitis HLS project output
├── tb/
│   ├── tb_top.v
│   ├── tb_<module>.v
│   └── stimulus/
├── sim/
│   ├── golden_model.py
│   ├── ml_golden.py
│   ├── feed_gen.py
│   ├── order_rx.py
│   └── compare.py
├── model/
│   ├── train.ipynb / train.py
│   ├── model_config.json
│   ├── weights.mem / bias.mem
│   ├── normalization.mem
│   └── golden_vectors.csv
├── constraints/
│   ├── tob_pins.xdc
│   └── tob_timing.xdc
├── scripts/
│   ├── build.tcl               # headless Vivado build
│   ├── build_hls4ml.py         # hls4ml convert + build + export IP
│   ├── run_sim.sh              # all tests, non-zero on failure
│   └── report.py               # parses reports into markdown tables
├── results/
│   ├── utilization.md
│   ├── timing.md
│   ├── latency_histogram.csv
│   ├── ml_metrics.md
│   └── ila_captures/
├── .github/workflows/ci.yml    # runs simulation + compares golden models
└── Makefile                    # make sim / synth / bit / ml / all
```

The README is a deliverable: block diagram, message-format table, decision rule in one line, risk-gate table (incl. `0x09`), reproduction commands, results tables, and — explicitly — the modelling assumptions (§4.3 snapshot-replace, §8.3 immediate fill, §5.2 proxy label). Stating limitations plainly reads as engineering judgement.

---

## 14. Extensions (Explicitly Out of Scope for v1)

1. **Multi-level order book** — 8+ price levels/side in BRAM, add/modify/cancel, new-best search. Natural v2.
2. **A/B feed arbitration** — two copies of each sequence number, take the first.
3. **Real exchange protocol decode** — NASDAQ ITCH 5.0 subset.
4. **Probabilistic fill model** — seeded PRNG shared with the golden model.
5. **Wider datapath** — 64-bit @125 MHz for 10G-class core (NFR-5).
6. **Order entry protocol** — simplified OUCH-style encoder.
7. **Softcore control plane** — MicroBlaze replacing CSR frames.
8. **Reloadable ML weights** — AXI/CSR-driven weight memory replacing baked constants.
9. **Larger ML models** — 8×8×1 MLP (v2), then a small LSTM/GRU over a rolling event window (hls4ml supports recurrent layers); requires `io_stream` and a bigger part or aggressive reuse.
10. **True fill-conditioned labels** — requires real fill/queue data; currently only a proxy.

---

## 15. Milestone Plan

Two-person plan. Review gate at the end of each stage; nothing proceeds past a gate with a failing test. Owner: **FPGA** = Sai, **ML** = collaborator, **Both** = shared.

| Stage | Days | Owner | Work | Gate |
| :-- | :-- | :-- | :-- | :-- |
| **S0 — Scaffold** | 1 | FPGA | Repo, Makefile, scripted Vivado build, CI, empty top | `make all` builds an empty bitstream; CI green |
| **S1 — Format + models** | 2 | Both | Freeze §4 format; `feed_gen.py`; `golden_model.py`; `ml_golden.py`; `train.py` | Golden models produce expected output for a hand-computed 20-message case |
| **S2 — Parser** | 3 | FPGA | `frame_classifier`, `md_parser`, module TBs | T01, T02, T05, T06 pass; 1M-message parse, zero loss |
| **S3 — Book + features** | 3 | FPGA | `symbol_filter`, `seq_monitor`, `tob_engine`, `feature_extractor`, `feature_normalizer` | T04, T08–T12, T27 pass |
| **S4 — ML off-chip** | 4 | ML | Train, quantize, export golden vectors; hls4ml convert (Vitis, `xc7a35tfgg484-2`); verify `trace()` == `ml_golden.py` | T28, T29, T35 (golden) pass; hls4ml builds clean on the part |
| **S5 — Signal** | 1 | FPGA | `signal_engine` | T13, T14 pass incl. exact thresholds |
| **S6 — ML integration** | 4 | Both | `ml_classifier_wrap`, `ml_policy`, alignment shift register, gate `0x09`, CSR ML regs | T30–T34, T36 pass in simulation; RTL == `ml_golden.py` bit-exact |
| **S7 — Risk** | 3 | FPGA | `risk_engine` (9 gates), position, throttle | T15–T21 pass; every gate counter provably incremented |
| **S8 — Egress** | 2 | FPGA | `order_builder`, framing, IPv4 checksum, MAC TX | Order frames decoded by `order_rx.py` |
| **S9 — Instrumentation** | 2 | FPGA | Timestamps, histogram, counters, CSR, stats | T24, T25 pass; single-bucket histogram in sim |
| **S10 — Integration** | 3 | FPGA | Full soak, timing closure @125 MHz, utilization | T26 passes; WNS > 0; NFR-7 met |
| **S11 — Hardware** | 5 | FPGA | Board bring-up, loopback, line-rate soak, ILA, scope, kill switch, ML on-board replay | §11.6 demonstrated |
| **S12 — Publish** | 3 | Both | README, diagrams, results tables, baselines (§12.5), demo video | Clean clone reproduces sim; blog + video ready |

**Fallback if the MAC is not ready at S8:** the engine-MAC interface is an 8-bit ready/valid stream; the MAC is replaceable without touching the engine. Proceed against a TB stream driver, use UART ingress (FR-59) for a functional hardware demo, and state which latency claims are simulation+ILA vs. wire-to-wire.

**Fallback if hls4ml blocks S6:** the classifier is architecturally isolated behind `ml_classifier_wrap.v`. A hand-written `linear_classifier.v` (8 MACs, ~50 lines) can stand in for the hls4ml IP with zero change to the rest of the design, so hls4ml can never block the FPGA schedule. Ship the hand-written version if necessary; add the hls4ml IP as soon as it builds.

---

## 16. Risks to the Project

| Risk | Impact | Mitigation |
| :-- | :-- | :-- |
| MAC not production-ready | Blocks S8/S11 | Abstracted ingress; UART fallback; MAC only on the wire-to-wire number |
| RGMII timing on JL2121(D) | Bring-up delay | Bring up the ALINX Ethernet example first; RX/TX clock delay is strap-configured (RXDLY/TXDLY pins, both already strapped +2ns on this board per `docs/refs/AX7035B_pinout_notes.md`), not register-configured — nothing for `mdio_ctrl.v` to tune here |
| hls4ml build fails on small part | Blocks S6 | `linear_classifier.v` fallback behind the same wrapper; hls4ml isolated by `ml_classifier_wrap` |
| DSP overrun on MLP v2 (72 MACs vs 90 DSP) | Fails NFR-7 | `ReuseFactor`/LUT multipliers; ship v1 (8 DSP) as the guaranteed fit |
| ap_fixed bit-exactness pain | Verification churn | Fix truncation/saturation/width in `ml_golden.py` at S1; lock arithmetic before RTL |
| Feature-history bug (F1/F3/F4/F5/F7) | Silent ML error | Unit-test each feature (T27); keep history in registers and reset explicitly |
| Alignment race (ML verdict vs order intent) | Undermines determinism | Make alignment depth a compile-time constant; assert arrival in the same cycle (T36) |
| Scope creep into a real order book | Schedule loss | §14 holds the line; multi-level book is v2 |
| Golden model written from RTL | Verification worthless | Write models at S1, before corresponding RTL |
| Timing closure at 125 MHz | Late rework | Known suspects: imbalance shifter, register-file mux, feature adder tree; keep `IMB_SHIFT` ≤ 3, `NUM_SYMBOLS` = 4 |
| Latency histogram shows spread | Undermines headline claim | Any second bucket = functional bug at S9, not tuning at S12 |

---

## 17. Open Questions

All resolved as of 2026-09-01 (rationale in `docs/design_decisions.md`, one entry `D1`–`D8` per decision). Kept here as a record, not a to-do list.

1. **MAC interface shape.** ~~Plain 8-bit valid/last stream, or AXI4-Stream?~~ **Resolved:** neither — a byte-push TX FIFO + whole-frame-buffered RX RAM, ALINX's `mac_top.v` boundary, adapted via a new `rtl/eth_mac_if.v`. See D1.
2. **MAC RX error signalling.** ~~Error flag after the fact, or frame suppressed?~~ **Resolved:** frame suppression, confirmed by reading `udp_rx.v`; patched to expose `mac_rec_error`/checksum-error as new output ports so FR-1's `err_fcs` counter is implementable. See D1, D5.
3. **`LINK_MODE` at bring-up.** ~~Raw-Ethernet first vs. UDP from S2?~~ **Resolved, reversed from the original lean:** UDP (`LINK_MODE=1`) first — the reused MAC only dispatches ARP/IPv4/UDP, so raw EtherType `0x88B5` would need a hand-modified vendor dispatch path. See D3.
4. **Board keys.** ~~AX7035B has two user keys?~~ **Resolved, premise corrected:** four keys (KEY1–KEY4). KEY1=kill switch, KEY2=counter/latch clear, KEY3=mode select (reserved), KEY4=spare. See D6.
5. **Reject reporting.** ~~Keep `0x11` diagnostic frames, or counters-only?~~ **Resolved:** counters-only gates S7; `0x11` frames are a post-S7 stretch goal (FR-44 already defaults them off). See D7.
6. **ML normalization: registers vs. baked.** **Resolved:** default kept — runtime registers.
7. **Gate `0x09` semantics.** **Resolved:** default kept — block-only for v1.
8. **Exact Vivado part string.** **Resolved 2026-09-01:** `xc7a35tfgg484-2` accepted by the installed Vivado 2024.2 (confirmed via `get_parts`).
9. **hls4ml version pin.** Still open — owned by the ML collaborator; pin in `docs/hls4ml_flow.md` when his toolchain is confirmed.

---

## 18. Project Significance (interview map)

What this project demonstrates, mapped to what FPGA/HFT hiring teams screen for:

| Skill | Where demonstrated |
| :-- | :-- |
| Fixed-latency pipelined datapath | §3.2 convergent paths, NFR-1/2, single-bucket histogram |
| Market-data parsing | §4, `md_parser`, streaming multi-message frames |
| Order-book state | §6.3, register-vs-BRAM reasoning |
| Fixed-point arithmetic discipline | §5.3–5.5, `int8 × int8 → int32`, saturation, bit-exact golden model |
| ML-on-FPGA toolchain (hls4ml) | §5.6, HLS → IP → wrapper integration |
| Quantized inference | §5.4, weights/threshold formats, DSP budget |
| Pre-trade risk controls | §8, nine gates incl. ML, non-bypassable fast-path risk |
| Verification rigor | §11, golden models from spec, counter conservation, 1M-message soak |
| Measured (not asserted) results | §12, latency/throughput/timing/utilization, ILA + scope |
| Honest scoping | §1.5, §5.2, §14 — simulated, proxy label, immediate fill |

**Thirty-second summary for interviews:**

> I built a pipelined FPGA market-data-to-order datapath on an Artix-7 that parses a Gigabit-Ethernet feed, maintains top-of-book state, extracts fixed-point features, and runs a quantized hls4ml-generated adverse-selection classifier as an additional non-bypassable risk gate. The ML verdict and the deterministic signal converge at the risk engine in the same cycle, so the whole path is a fixed ~20-cycle tick-to-trade latency — verified bit-exact against a Python golden model over a million-message soak, with timing and utilization published.
