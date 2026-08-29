# fpga-top-of-book-engine — Project Specification

**A low-latency market-data-to-order datapath on an Artix-7 FPGA**

| Field | Value |
| :-- | :-- |
| Version | 1.0 (draft for review) |
| Author | Sai Charan Raghupatruni |
| Target device | Xilinx Artix-7 `XC7A35T-2FGG484I` (ALINX AX7035B) |
| Ethernet PHY | Micrel KSZ9031RNX, RGMII, 10/100/1000 Mbps |
| RTL language | Verilog-2001 (synthesizable subset) |
| Toolchain | Vivado 2023.x or later, Python 3.11+ for models and tooling |
| Core clock | 125 MHz (8 ns period), single clock domain for the engine |
| Planned effort | 10–14 calendar days, portfolio-grade deliverable |
| Repository name | `fpga-top-of-book-engine` |

---

## 1. Problem Statement

### 1.1 The situation this design lives in

An electronic exchange broadcasts a continuous stream of small binary messages describing what is happening to the prices of the instruments it lists. A trading firm receives that stream over a network cable, decides whether the new information creates an opportunity, and — if it does — sends an order back to the exchange.

Everyone receives the same broadcast at roughly the same instant. The firms that profit from short-lived opportunities are therefore not the ones with better information; they are the ones whose reaction arrives first. When a price moves, dozens of participants want to act on the same fact, and typically only the earliest one or two orders to reach the exchange's matching engine are actually filled. Everything after that is a wasted message.

This makes the elapsed time between "the last bit of a market-data message arrives at the network port" and "the first bit of the resulting order leaves the network port" the single most valuable engineering quantity in the system. In the industry this interval is called **tick-to-trade latency**.

### 1.2 Why this is a hardware problem, not a software problem

A conventional software implementation of the same task — a program running on a CPU under Linux — has to move each incoming packet through a network interface card, a driver interrupt, the kernel network stack, a socket buffer, a scheduler decision, and finally user-space application code, then reverse the whole journey on the way out. Each of those stages costs time, and — more importantly — costs a *variable* amount of time. A software path might average a few microseconds but occasionally take fifty, because another process was scheduled, a cache missed, or a page faulted.

Two distinct properties matter here and they are frequently confused:

- **Latency** is how long the reaction takes.
- **Determinism** is how tightly that duration is bounded — whether the slowest reaction is close to the typical one.

A strategy sized around a 2 µs reaction that occasionally takes 50 µs is not a 2 µs strategy; it is a strategy that is periodically and unpredictably wrong, and those occasions correlate with exactly the busy moments when the opportunity existed. Determinism is often worth more than raw speed.

An FPGA changes the shape of the problem. Instead of instructions executed one after another on shared general-purpose hardware, the design becomes a fixed physical path through dedicated logic. Bytes enter the parser and propagate through decode, book update, signal evaluation, and risk checking as a pipeline — an assembly line where each stage works on a different message simultaneously. The number of clock cycles from input to output is a property of the circuit, not of what else is happening in the machine. It is the same on the busiest microsecond of the day as on the quietest.

### 1.3 What is actually being built

This project implements the latency-critical portion of that pipeline in RTL, end to end, on real hardware, with the timing measured rather than asserted.

The design receives a synthetic market-data feed over Gigabit Ethernet. It parses the frames, discards every instrument it does not care about, maintains the current best bid and best ask for the instruments it does care about, evaluates a fixed trading rule against that state, passes any resulting order intent through a set of pre-trade risk gates, and emits a simulated order back over Ethernet. Alongside the datapath it maintains a hardware latency histogram measuring its own tick-to-trade time in clock cycles.

The reason for including the risk gates — rather than treating them as an optional extra — is that they are the part practitioners take most seriously and that student projects most often omit. A system that can send orders in 200 ns can also send *wrong* orders in 200 ns, and can send several thousand of them before a human notices anything. Every real trading system therefore places a set of hard, non-bypassable checks in the same fast path as the strategy, because a control that lives on a slower path is not a control at all. Building the risk gates into the pipeline, at the same speed as the decision logic, is a substantial part of the point of the exercise.

### 1.4 What is deliberately excluded

This is a **simulated** trading system. It never connects to a real exchange, never carries real orders, and never handles money. That is the correct scope: the engineering is authentic while the regulatory, financial, and operational hazards of live order entry are absent entirely. The "exchange" is a Python program on a laptop that generates a feed and receives the resulting orders.

The design also deliberately avoids reimplementing a production exchange protocol, a full TCP/IP stack, or a deep multi-level order book in version 1. Each of those is a large project on its own, and each would consume the schedule without teaching anything additional about the core question of how to build and verify a fast, deterministic datapath. They are noted as extensions in §14.

### 1.5 Success criteria

The project succeeds if all of the following are demonstrated and documented:

1. The engine processes back-to-back market-data messages at Gigabit line rate without dropping or reordering any message, verified over a run of at least 1,000,000 messages.
2. Tick-to-trade latency, measured in hardware, is **fixed** — the histogram shows a single occupied bucket for the accepting path, with the maximum equal to the minimum.
3. Every risk gate is individually demonstrated blocking an order that would otherwise have been sent, with a counter recording the rejection and its reason.
4. The RTL output matches a bit-exact Python golden model on every message of a randomized soak test, checked automatically.
5. The design meets timing at 125 MHz on the target part with positive worst negative slack, and the utilization and timing reports are published.
6. A person unfamiliar with the project can clone the repository, run one command, and reproduce the simulation results.

### 1.6 The one-sentence version

> A pipelined Artix-7 datapath that receives a Gigabit Ethernet market-data feed, parses and filters it, maintains top-of-book state, evaluates a trading signal, enforces pre-trade risk limits, and emits a simulated order — at a measured, fixed tick-to-trade latency, verified against a golden model.

---

## 2. Domain Glossary

Terms are defined here so the rest of the specification can use them without interruption. Everything is stated in plain language first.

| Term | Meaning in this project |
| :-- | :-- |
| **Instrument / symbol** | A tradable thing, e.g. a stock. Identified in this design by an 8-bit `symbol_id`, not a text ticker, because comparing an 8-bit integer costs one clock cycle and comparing an ASCII string does not. |
| **Bid** | The highest price anyone is currently willing to pay. |
| **Ask (offer)** | The lowest price anyone is currently willing to accept. |
| **Top of book (TOB)** | The best bid and best ask, with their sizes. The single most-used summary of a market's state. |
| **Spread** | Ask price minus bid price. Always ≥ 0 in a healthy market. |
| **Mid** | The midpoint, `(bid + ask) / 2`. Used here as a reference for the price-band risk check. |
| **Tick** | The smallest legal price increment. All prices in this design are integers counting ticks, never floating point — see §4.2. |
| **Crossed book** | Bid ≥ ask. Physically impossible in a consistent market; if seen, the data is stale, corrupt, or misordered. Must be detected and must suppress trading. |
| **Locked book** | Bid == ask. Unusual but not impossible; treated here as non-tradable. |
| **Imbalance** | A comparison of the size resting on the bid against the size resting on the ask. Heavier bid size is loosely read as short-term upward pressure. |
| **Signal** | The fixed rule that turns market state into an order intent. |
| **Order intent** | A proposed order that has not yet passed risk checks. |
| **Pre-trade risk** | Hard checks applied to every order intent before it can leave the system. Non-bypassable. |
| **Kill switch** | A single input that immediately and latchingly blocks all outbound orders, requiring an explicit operator action to clear. |
| **Position / inventory** | Net quantity currently held. Long = positive, short = negative. |
| **Adverse selection** | Being filled just before the price moves against you — the main hazard the speed is defending against. |
| **Tick-to-trade** | Elapsed time from arrival of the triggering market-data message to departure of the resulting order. The headline metric. |
| **Sequence number** | A counter the feed puts on every message so the receiver can detect loss. A gap means data was missed and the book is no longer trustworthy. |
| **Line rate** | The maximum sustained message rate the physical link can carry. Here, Gigabit Ethernet. |
| **Backpressure** | A downstream block telling an upstream block to pause. In this design the datapath is built so that it never needs to (§6.4). |

---

## 3. System Architecture

### 3.1 Block diagram

```text
   ┌──────────────────────────────────────────────────────────────┐
   │  HOST PC (Python)                                            │
   │  feed_gen.py  ──► synthetic market data (UDP)                │
   │  order_rx.py  ◄── simulated orders + stats (UDP)             │
   │  golden_model.py ── bit-exact reference implementation       │
   └────────────────────────┬─────────────────────────────────────┘
                            │ 1000BASE-T
                    ┌───────▼────────┐
                    │  KSZ9031RNX    │  PHY
                    └───────┬────────┘
                            │ RGMII (4-bit DDR @125 MHz)
   ═════════════════════════▼══════════════════════════════════════
   FPGA — XC7A35T                              all @ 125 MHz, 8-bit
   ┌────────────────────────────────────────────────────────────┐
   │ [A] rgmii_to_gmii        DDR ↔ SDR conversion              │
   │ [B] eth_mac_rx           preamble/SFD strip, FCS check     │  ← existing MAC
   │ ├──────────────────────────────────────────────────────────┤
   │ [C] frame_classifier     EtherType / IPv4 / UDP port match │
   │ [D] md_parser            byte-serial → structured message  │  ═ TIMESTAMP IN
   │ [E] symbol_filter        4-entry symbol CAM                │
   │ [F] seq_monitor          gap detection, staleness          │
   │ [G] tob_engine           best bid/ask registers per symbol │
   │ [H] signal_engine        spread + imbalance rule           │
   │ [I] risk_engine          8 gates, position, throttle       │
   │ [J] order_builder        order record → frame              │  ═ TIMESTAMP OUT
   │ [K] eth_mac_tx           FCS append, IFG                   │  ← existing MAC
   │ ├──────────────────────────────────────────────────────────┤
   │ [L] latency_histogram    BRAM, 64 buckets                  │
   │ [M] csr_block            config + counters, UDP-addressed  │
   │ [N] stats_reporter       periodic stats frame emitter      │
   │ [O] debug_uart           fallback ingress + status dump    │
   └────────────────────────────────────────────────────────────┘
        │                              │
    KEY[0] kill switch            LED[3:0] status
```

### 3.2 Datapath partitioning rationale

The blocks divide into three groups with different design rules, and keeping that division explicit is the main architectural decision in the project.

**The fast path (C → J)** is fully pipelined, has no stalls, no arbitration, no dynamic memory, and no state machine that can take a variable number of cycles for the same input. Its latency is a constant determined at synthesis time. Everything on this path is justified by whether it must be there to produce a correct order.

**The slow path (L, M, N, O)** does configuration, statistics, and reporting. It may take as long as it likes. It is architecturally forbidden from ever asserting backpressure onto the fast path — a stats reader must never be able to delay an order.

**The control plane (M, kill switch)** writes configuration into registers that the fast path reads combinationally. Configuration changes take effect on the next message; there is no negotiation and no handshake, because a handshake would be a variable-latency dependency.

This mirrors how production systems are partitioned: the FPGA carries the narrow, repetitive, latency-critical path, and everything requiring flexibility, analytics, or human interaction is pushed off it.

---

## 4. Feed and Wire Format

### 4.1 Link-layer modes

The design supports two ingress framings, selected by the `LINK_MODE` parameter. Both are specified because they trade realism against bring-up time.

**Mode 0 — Raw Ethernet (`LINK_MODE = 0`), default for bring-up.**
Custom EtherType `0x88B5` (an IEEE-reserved local-experimental value). No IP, no UDP, no ARP, no checksums beyond the Ethernet FCS. Payload begins immediately at byte 14 of the frame. This mode exists so that hardware bring-up is not blocked on IP-stack debugging; the host side uses a raw socket.

**Mode 1 — UDP/IPv4 (`LINK_MODE = 1`), the realistic mode.**
EtherType `0x0800`, IPv4 header (version 4, IHL 5, no options — any frame with IHL ≠ 5 is discarded), protocol 17 (UDP), destination UDP port matched against a configurable register (default `0xEA60` = 60000). The IPv4 header checksum **is** verified on receive; the UDP checksum is **not** (it is optional under IPv4 and verifying it would require buffering the whole datagram before acting, which would destroy the latency property — this is a real and defensible design trade-off and should be stated as such in the README).

For Mode 1 the host must have a static ARP entry for the FPGA, because ARP responding is not implemented in v1:

```bash
sudo arp -s 192.168.1.10 00:0a:35:01:02:03
```

Transmit in either mode uses destination MAC/IP/port values held in configuration registers, so no address resolution is needed outbound.

### 4.2 Prices are integers

All prices are unsigned integers counting ticks. `$100.01` with a `$0.01` tick is transmitted as `10001`.

This is not a simplification made for convenience; it is what production systems do, for three reasons. Floating-point comparison is inexact, and a trading system must be able to say two prices are equal with certainty. Floating-point arithmetic on an FPGA costs DSP slices and multiple cycles of latency where integer comparison costs one LUT level. And price arithmetic in this domain is inherently discrete — prices genuinely move in fixed increments, so representing them as continuous quantities is modelling the world incorrectly.

### 4.3 Market-data message format

Fixed width, 16 bytes, big-endian (network byte order). Fixed width is a deliberate choice: a variable-length format would require the parser to compute where the next message starts before it can begin parsing it, which serializes what should be pipelined.

| Offset | Size | Field | Description |
| :-- | :-- | :-- | :-- |
| 0 | 1 | `msg_type` | `0x01` quote update, `0x02` trade print, `0x03` book clear, `0xFF` heartbeat |
| 1 | 1 | `symbol_id` | Instrument identifier, 0–255 |
| 2 | 1 | `side` | `0x00` bid, `0x01` ask, `0xFF` not applicable (trade/heartbeat) |
| 3 | 1 | `flags` | bit0 = end-of-burst, bit1 = snapshot, bits 7:2 reserved (must be 0) |
| 4 | 4 | `price` | Price in ticks, unsigned |
| 8 | 4 | `quantity` | Size in shares/lots, unsigned |
| 12 | 4 | `seq_num` | Monotonically increasing per feed, wraps at 2³² |

**Update semantics for v1: snapshot-replace per side.** A `msg_type = 0x01` message states *the current best price and size* for the given side of the given symbol. It replaces the stored value; it is not a delta or an add/cancel instruction.

This is the most important modelling decision in the project and it must be stated plainly in the README, because it is the difference between this design and a real order book. Real exchange feeds send incremental add/modify/cancel messages, and reconstructing the top of book from them requires maintaining every price level and finding the new best whenever the current best is removed. That is a substantially larger problem (§14.1). Choosing snapshot-replace keeps v1's book update at one clock cycle, which is what makes the rest of the pipeline meaningful. Normalized top-of-book feeds with exactly these semantics do exist commercially, so the model is not fictional — it is simply the easy end of a real spectrum.

A `msg_type = 0x03` (book clear) resets that symbol's stored state to "invalid" and suppresses signals until both sides have been repopulated. This exists to exercise the invalid-state path.

### 4.4 Packing

One Ethernet frame may carry between 1 and 88 messages (88 × 16 = 1408 bytes, fitting a 1500-byte MTU with IP/UDP headers). Messages are packed back to back with no padding. A frame carrying a non-multiple of 16 payload bytes is a malformed frame: it is discarded in whole, the `err_frame_len` counter increments, and the parser resets cleanly to await the next frame.

Multiple messages per frame is not decoration — it is how real feeds behave, and it is what forces the parser to be a streaming design rather than a "wait for the frame, then process" design.

### 4.5 Order output message format

Fixed width, 16 bytes, big-endian. One order per frame in v1 (latency beats efficiency here; batching orders would mean the first order waits for the second).

| Offset | Size | Field | Description |
| :-- | :-- | :-- | :-- |
| 0 | 1 | `msg_type` | `0x10` new order, `0x11` risk reject (diagnostic), `0x12` stats |
| 1 | 1 | `symbol_id` | Instrument |
| 2 | 1 | `side` | `0x00` buy, `0x01` sell |
| 3 | 1 | `reject_reason` | `0x00` if accepted; otherwise the gate ID from §8.2 |
| 4 | 4 | `price` | Limit price in ticks |
| 8 | 4 | `quantity` | Order size |
| 12 | 2 | `trigger_seq` | Low 16 bits of the sequence number that caused this order |
| 14 | 2 | `latency_cyc` | Measured tick-to-trade latency in 125 MHz cycles |

Emitting `latency_cyc` inside the order message itself is a deliberate touch: it means the host's capture of the order stream is simultaneously a latency log, with no separate instrumentation channel to keep in sync.

---

## 5. Functional Requirements

Each requirement is numbered, independently testable, and mapped to a test in §11.4.

### 5.1 Ingress and framing

| ID | Requirement |
| :-- | :-- |
| FR-1 | The design shall receive Ethernet frames from the GMII interface of the existing MAC and shall process only frames whose FCS check passed. Frames with FCS errors shall be discarded silently and shall increment `err_fcs`. |
| FR-2 | In `LINK_MODE = 0` the design shall accept frames with EtherType `0x88B5` and treat byte 14 onward as message payload. |
| FR-3 | In `LINK_MODE = 1` the design shall accept frames with EtherType `0x0800`, IPv4 IHL = 5, valid IPv4 header checksum, protocol = 17, and UDP destination port equal to `cfg_udp_port`. Frames failing any condition shall be discarded and increment the matching counter. |
| FR-4 | The design shall accept payloads containing 1 to 88 packed 16-byte messages and shall parse every message in the frame. |
| FR-5 | A payload whose length is not an exact multiple of 16 bytes shall cause the entire frame to be discarded, `err_frame_len` to increment, and the parser to return to idle before the next frame's start. |
| FR-6 | The parser shall accept frames arriving with the minimum Ethernet inter-frame gap without loss. |

### 5.2 Filtering and validation

| ID | Requirement |
| :-- | :-- |
| FR-7 | The design shall maintain a configurable set of `NUM_SYMBOLS` (default 4) watched `symbol_id` values and shall forward only messages whose symbol matches one of them. Non-matching messages shall increment `cnt_filtered` and shall have no other effect. |
| FR-8 | The design shall discard messages with `msg_type` outside the defined set, incrementing `err_msg_type`. |
| FR-9 | The design shall discard messages with reserved `flags` bits set, incrementing `err_flags`. |
| FR-10 | The design shall track the expected next `seq_num` per feed. A received `seq_num` greater than expected shall increment `cnt_seq_gap` by the size of the gap, set the `seq_gap` sticky status bit, and assert the stale condition. |
| FR-11 | A received `seq_num` less than expected (duplicate or reordered) shall cause the message to be dropped and `cnt_seq_dup` to increment. It shall not modify book state. |
| FR-12 | The `seq_gap` condition shall clear only when a message with `flags.snapshot = 1` is received, or when explicitly cleared via CSR. |

### 5.3 Top-of-book state

| ID | Requirement |
| :-- | :-- |
| FR-13 | For each watched symbol the design shall hold `bid_price`, `bid_qty`, `ask_price`, `ask_qty`, and per-side `valid` bits. |
| FR-14 | A `msg_type = 0x01` message shall replace the price and quantity of the addressed side of the addressed symbol and set that side's `valid` bit, in a single clock cycle. |
| FR-15 | A `msg_type = 0x01` message with `quantity = 0` shall clear that side's `valid` bit (the level has been withdrawn) without altering the stored price. |
| FR-16 | A `msg_type = 0x03` message shall clear both `valid` bits for the addressed symbol. |
| FR-17 | The design shall detect a crossed book (`bid_price >= ask_price` with both sides valid), set the `crossed` status bit for that symbol, and increment `cnt_crossed`. |
| FR-18 | Book state shall be initialized to invalid on reset. No stale value from a previous run shall be readable after reset. |
| FR-19 | `msg_type = 0x02` (trade print) and `0xFF` (heartbeat) shall not modify book state. Heartbeats shall refresh the staleness timer; trade prints shall increment `cnt_trades`. |

### 5.4 Signal

| ID | Requirement |
| :-- | :-- |
| FR-20 | After each book-modifying update the design shall evaluate the buy rule: both sides valid, book not crossed, `spread >= cfg_min_spread`, and `bid_qty > (ask_qty << cfg_imb_shift)`. |
| FR-21 | It shall evaluate the mirrored sell rule: both sides valid, book not crossed, `spread >= cfg_min_spread`, and `ask_qty > (bid_qty << cfg_imb_shift)`. |
| FR-22 | Both rules satisfied simultaneously shall be impossible by construction; if the condition is ever detected, no order shall be emitted and `err_signal_conflict` shall increment. |
| FR-23 | A satisfied buy rule shall produce an order intent to buy `cfg_order_qty` at `ask_price`; a satisfied sell rule, to sell `cfg_order_qty` at `bid_price`. |
| FR-24 | Signal evaluation shall use only shifts, comparisons, and subtraction. No multipliers and no DSP slices shall be inferred on the fast path. |
| FR-25 | The signal shall be evaluated on every book-modifying message, not on a timer, and shall not require the message to have changed the book's value. |

### 5.5 Risk

| ID | Requirement |
| :-- | :-- |
| FR-26 | Every order intent shall pass through all gates in §8.2 before any byte of an order frame is emitted. There shall be no code path that emits an order bypassing the risk engine. |
| FR-27 | The risk engine shall evaluate all gates in parallel within a single clock cycle. |
| FR-28 | A blocked order shall increment the counter for its specific gate. Where multiple gates block simultaneously, the lowest-numbered gate shall be reported as `reject_reason`, and every triggered gate's counter shall increment. |
| FR-29 | When `cfg_reject_report = 1` the design shall emit a `msg_type = 0x11` diagnostic frame for blocked orders. When 0, blocked orders produce counters only. This shall be off by default so that diagnostics cannot influence measured behaviour. |
| FR-30 | The design shall maintain a signed net position per symbol, updated on each accepted order under the fill model of §8.3. |
| FR-31 | Asserting the kill switch shall block all outbound orders within one clock cycle of the input being registered, and shall latch. Deassertion of the input alone shall not resume trading; an explicit CSR clear shall be required. |
| FR-32 | The kill switch shall be readable as a status bit and shall drive a dedicated LED. |

### 5.6 Egress

| ID | Requirement |
| :-- | :-- |
| FR-33 | An accepted order shall be encoded per §4.5 and transmitted through the MAC as a single frame, with correct framing for the active `LINK_MODE` (including IPv4 header checksum in Mode 1). |
| FR-34 | Order emission shall begin at a fixed cycle offset from the ingress timestamp point for every accepting message, independent of message content, symbol, or system history. |
| FR-35 | The design shall not reorder orders relative to the market-data messages that triggered them. |
| FR-36 | If a market-data message arrives while an order frame is in transmission, the incoming message shall still be parsed and applied to the book. Only the *transmission* of a subsequent order may queue (§6.5). |

### 5.7 Measurement and control

| ID | Requirement |
| :-- | :-- |
| FR-37 | A free-running 32-bit cycle counter shall run at 125 MHz. Its value shall be captured at the ingress timestamp point (last byte of a message entering the parser) and carried with that message through the pipeline. |
| FR-38 | At the egress timestamp point (first byte of the order handed to the MAC TX) the design shall compute latency as the difference and record it in a 64-bucket histogram in BRAM. |
| FR-39 | The design shall maintain `lat_min`, `lat_max`, and `lat_last` registers. |
| FR-40 | Counters and histogram shall be readable via a stats frame emitted every `cfg_stats_period` cycles, and on demand via a CSR read request frame. |
| FR-41 | Reading statistics shall never stall, delay, or otherwise affect the fast path. |
| FR-42 | All configuration values in §9 shall be writable via CSR write frames and shall take effect on the next message boundary. |
| FR-43 | The engine shall provide a UART fallback ingress accepting the same 16-byte message format, for hardware bring-up without Ethernet. Latency measurement is not meaningful in this mode and shall be flagged as such. |

---

## 6. Non-Functional Requirements

### 6.1 Latency

| ID | Requirement |
| :-- | :-- |
| NFR-1 | Tick-to-trade latency from the ingress timestamp point to the egress timestamp point shall be a fixed constant, identical for every accepting message. Target ≤ 10 cycles (80 ns). |
| NFR-2 | The measured histogram shall show exactly one occupied bucket for the accepting path across the full soak test. Any second occupied bucket is a functional bug, not a performance result. |
| NFR-3 | The wire-to-wire latency including the existing MAC RX and TX shall be measured separately and reported as a budget table (§12.3). |

### 6.2 Throughput

| ID | Requirement |
| :-- | :-- |
| NFR-4 | The engine shall sustain one 16-byte message every 16 cycles indefinitely — the maximum a 1 Gbps 8-bit-per-cycle link can deliver — with zero drops. |
| NFR-5 | The internal pipeline shall be capable of accepting one message per cycle, so that widening the ingress path in a future revision requires no change to the engine's core. |

### 6.3 Timing and resources

| ID | Requirement |
| :-- | :-- |
| NFR-6 | The design shall meet timing at 125 MHz on `XC7A35T-2FGG484I` with WNS > 0 after place and route. |
| NFR-7 | Engine logic excluding the MAC shall consume ≤ 15% of the part's LUTs (≈3,100 of 20,800), ≤ 10% of FFs, ≤ 8 BRAM36 of 50, and 0 DSP slices. |
| NFR-8 | The engine shall use a single 125 MHz clock domain. Any clock-domain crossing (UART, buttons) shall be confined to the slow path with explicit two-flop synchronizers and shall be documented. |

### 6.4 Design constraints

| ID | Requirement |
| :-- | :-- |
| NFR-9 | RTL shall be Verilog-2001, synthesizable subset. No SystemVerilog constructs in the `rtl/` tree. |
| NFR-10 | No inferred latches. No combinational feedback loops. No asynchronous resets except the top-level power-on reset, which shall be synchronized before use. |
| NFR-11 | No dynamic memory allocation, no variable-iteration loops, no arbitration on the fast path. Every fast-path structure shall have a fixed depth known at elaboration. |
| NFR-12 | The fast path shall contain no FIFO whose fullness can vary as a function of message content. |
| NFR-13 | All magic numbers shall be `parameter` or `localparam`. Configurable behaviour shall be register-driven, not recompiled. |

### 6.5 On backpressure

The fast path is built to be stall-free, and the reasoning belongs in the spec rather than in a comment. The parser consumes 8 bits per cycle because the MAC delivers 8 bits per cycle; the book update is single-cycle; signal and risk are combinational stages with registered outputs. No stage can consume slower than its predecessor produces, so no stage can ever need to push back.

The one place where queueing genuinely can occur is order transmission: an order frame occupies the TX path for roughly 84 cycles (64-byte minimum frame plus interframe gap), and it is arithmetically possible for the signal to fire again before it finishes. The design handles this with a **2-deep order output register, not a deep FIFO**, and an explicit overflow policy: if a third order is generated while two are pending, the newest is dropped and `cnt_order_overflow` increments.

Dropping is the correct behaviour and the reasoning is worth stating in the README. A queue of stale orders is worse than no order — by the time a queued order reaches the exchange the opportunity that justified it has passed, and sending it means trading on information known to be out of date. Real systems drop rather than queue for exactly this reason. It also keeps latency deterministic: an unbounded queue would make the tick-to-trade time depend on history, which would violate NFR-1.

---

## 7. Module Specifications

Interfaces use ready/valid handshaking in AXI-Stream style throughout, even on the internal 8-bit paths, so that stages compose predictably and can later be widened.

### 7.1 `md_parser`

Converts the byte stream into structured messages.

```verilog
module md_parser #(
    parameter MSG_BYTES = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    // byte stream in (from frame_classifier)
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,     // end of frame
    input  wire        s_axis_tuser,     // frame error, discard
    // structured message out
    output reg         m_msg_valid,
    output reg  [7:0]  m_msg_type,
    output reg  [7:0]  m_msg_symbol,
    output reg  [7:0]  m_msg_side,
    output reg  [7:0]  m_msg_flags,
    output reg  [31:0] m_msg_price,
    output reg  [31:0] m_msg_qty,
    output reg  [31:0] m_msg_seq,
    output reg  [31:0] m_msg_ts,         // ingress timestamp
    // errors
    output reg         err_frame_len
);
```

Implementation: a 4-bit byte counter and a shift-accumulate register. Each incoming byte shifts into a 128-bit accumulator; on the 16th byte the fields are sliced out and `m_msg_valid` is asserted for one cycle, and the counter wraps to begin the next message immediately. `m_msg_ts` is captured on that same cycle — this is the **ingress timestamp point**, and its placement is a judgement worth defending in an interview: it is the earliest instant at which the message's content is fully known, so it isolates the engine's own latency from the MAC's.

`s_axis_tlast` with a non-zero byte counter means the frame ended mid-message: assert `err_frame_len`, reset the counter, do not emit.

### 7.2 `symbol_filter`

A 4-entry content-addressable comparison. Four parallel equality comparators against `cfg_symbol[0..3]`, each gated by a `cfg_symbol_en` bit, ORed together. Output is the message plus a 2-bit `slot_id` naming which storage slot the symbol maps to. Purely combinational with a registered output — one cycle.

A **content-addressable memory (CAM)** is a memory you query by content rather than by address: you present a value and it tells you where, if anywhere, that value is stored. Regular memory answers "what is at address 7"; a CAM answers "which address holds the value 10001". In hardware a small CAM is simply N comparators running in parallel, which is why it costs one cycle regardless of N — and equally why it stops being viable as N grows, since area and fanout scale linearly. At four entries it is trivial; at four thousand it would need a hash table or a BRAM-based lookup with multi-cycle latency, which is the real reason this design watches a handful of symbols rather than a whole market.

### 7.3 `tob_engine`

Register-based storage, `NUM_SYMBOLS × {bid_price, bid_qty, ask_price, ask_qty, bid_valid, ask_valid}`. Registers rather than BRAM at this size: BRAM has a one-cycle read latency and would add a cycle to the critical path for no area benefit at 4 symbols. Update is a one-cycle write to the slot addressed by `slot_id` and `side`. Outputs the full post-update state combinationally to the signal engine, plus a `crossed` flag.

The register-versus-BRAM boundary is worth documenting: at roughly 16 symbols the register file's mux depth begins to hurt timing and BRAM becomes the better structure, at the cost of a pipeline stage. That crossover is the kind of thing an interviewer will probe.

### 7.4 `signal_engine`

Combinational evaluation of the §5.4 rules with registered output. `spread = ask_price - bid_price` (single subtractor). Imbalance uses a barrel-shift comparison, `bid_qty > (ask_qty << cfg_imb_shift)`.

A **barrel shifter** is a circuit that shifts a value by a variable number of positions in one pass, built as a tree of multiplexer stages — one stage per bit of the shift amount, each stage either passing its input through or shifting it by a fixed power of two. It matters here because the shift amount is a runtime register, not a constant: a constant shift is free (it is just rewiring), while a variable shift costs real logic and appears on the critical path. Restricting `cfg_imb_shift` to 0–3 keeps the shifter two stages deep and out of trouble; allowing an arbitrary 32-bit shift would not.

### 7.5 `risk_engine`

All gates evaluated in parallel from registered inputs, results ORed into a single `block` signal with a priority encoder producing `reject_reason`.

A **priority encoder** takes a set of parallel condition bits and outputs the index of the highest-priority one that is asserted. It is used here because several gates can fire on the same order and the reject *reason* must be a single value, while the *counters* must all increment — so the encoder feeds the reason field only, and the raw bit vector feeds the counters. Its cost is a chain of comparisons whose depth grows with the number of inputs, which is fine at eight and would need a tree structure at sixty-four.

### 7.6 `order_builder`

Serializes the accepted order record into bytes, prepends the framing for the active `LINK_MODE`, computes the IPv4 header checksum (precomputable, since only the length field varies and the length is constant here), and hands the stream to the MAC TX. The **egress timestamp point** is the cycle on which the first payload byte is presented to the MAC.

### 7.7 `latency_histogram`

A 64 × 32-bit BRAM. The latency value indexes the bucket directly for values under 64; anything ≥ 64 lands in the saturating top bucket. Read-modify-write with a bypass register to handle back-to-back writes to the same bucket. Entirely off the fast path — it observes the egress event and never gates it.

---

## 8. Risk Engine Specification

### 8.1 Design principle

The risk gates are not a feature bolted onto the strategy; they are the last stage of the fast path and they run at the same speed as everything else. Any implementation in which risk lives on a slower path, or can be disabled by configuration, or can be bypassed by a particular code path, fails FR-26. This is the requirement to defend most carefully during implementation, because it is the one most easily broken by a well-intentioned optimization.

### 8.2 Gates

| ID | Gate | Condition to block | Rationale |
| :-- | :-- | :-- | :-- |
| `0x01` | Kill switch | `kill_latched` asserted | Operator or automated halt. Overrides everything. |
| `0x02` | Max order size | `order_qty > cfg_max_order_qty` | A single fat-finger or logic error must not produce an unbounded order. |
| `0x03` | Max position | `\|position ± order_qty\| > cfg_max_position` | Bounds total exposure, not just per-order exposure. |
| `0x04` | Price band | `\|order_price - mid\| > cfg_price_band` | Rejects orders far from the current market — the classic protection against acting on corrupt price data. |
| `0x05` | Stale data | `cycles_since_update > cfg_max_age` | If the feed has gone quiet, the book is a guess. Do not trade on a guess. |
| `0x06` | Sequence gap | `seq_gap` sticky bit set | Messages were missed; book state is unreliable until resynchronized. |
| `0x07` | Crossed/locked book | `bid_price >= ask_price` | Physically impossible state — indicates corrupt or misordered data. |
| `0x08` | Order rate throttle | Token bucket empty | Exchanges impose message-rate limits and penalize breaches; also bounds the damage from a logic error that fires continuously. |

### 8.3 Position and fill model

Because there is no real exchange, a fill model is required, and its assumptions must be explicit rather than buried in the RTL.

**v1 model: immediate full fill.** An accepted order is assumed to execute completely at its limit price on the cycle it is emitted. `position` updates by `+order_qty` for a buy and `-order_qty` for a sell.

This is optimistic, and the README should say so directly. Real orders are partially filled, rejected, or queued behind others, and a market-making strategy's actual difficulty lies precisely in the orders that do *not* fill the way you hoped. The model is chosen because it makes the position counter deterministic and therefore checkable against the golden model, which is the property the verification effort depends on. A probabilistic fill model is listed as an extension (§14.4) and would require the golden model and the RTL to share a seeded PRNG — solvable, but not a v1 problem.

### 8.4 Token bucket throttle

A **token bucket** is a rate limiter holding a counter of "permits". Each order consumes one; permits are replenished at a fixed rate up to a ceiling. It permits short bursts up to the ceiling while bounding the long-run average — which matches how exchange rate limits actually work, and is why it is used here rather than a simple "one order per N cycles" gate that would forbid legitimate bursts.

Parameters: `cfg_token_max` (default 8), `cfg_token_refill_cycles` (default 12500 = one token per 100 µs).

---

## 9. Configuration Register Map

Accessed via CSR frames (`msg_type = 0x20` write, `0x21` read request, `0x22` read response). All registers are 32-bit.

| Addr | Name | Default | Description |
| :-- | :-- | :-- | :-- |
| `0x00` | `CTRL` | `0x0` | bit0 engine enable, bit1 kill clear (self-clearing), bit2 counter clear, bit3 seq-gap clear, bit4 reject reporting |
| `0x04` | `STATUS` | — | bit0 kill latched, bit1 seq gap, bit2 crossed, bit3 stale, bits 7:4 side-valid map |
| `0x08` | `SYMBOL_0..3` | `1,2,3,4` | Watched symbol IDs, one per register through `0x14` |
| `0x18` | `SYMBOL_EN` | `0xF` | Per-slot enable bits |
| `0x1C` | `MIN_SPREAD` | `2` | Minimum spread in ticks for the signal |
| `0x20` | `IMB_SHIFT` | `1` | Imbalance shift, range 0–3 |
| `0x24` | `ORDER_QTY` | `100` | Size of generated orders |
| `0x28` | `MAX_ORDER_QTY` | `500` | Gate `0x02` limit |
| `0x2C` | `MAX_POSITION` | `1000` | Gate `0x03` limit, symmetric |
| `0x30` | `PRICE_BAND` | `50` | Gate `0x04` limit in ticks |
| `0x34` | `MAX_AGE` | `1250000` | Gate `0x05` limit in cycles (10 ms) |
| `0x38` | `TOKEN_MAX` | `8` | Throttle ceiling |
| `0x3C` | `TOKEN_REFILL` | `12500` | Cycles per token |
| `0x40` | `UDP_PORT` | `60000` | Ingress UDP port, Mode 1 |
| `0x44` | `STATS_PERIOD` | `12500000` | Stats frame interval (100 ms) |
| `0x48`+ | Counters | — | Read-only block, §10 |

---

## 10. Counter Set

Every counter is 32-bit, saturating rather than wrapping, and clearable via `CTRL.bit2`. Saturating rather than wrapping matters: a wrapped counter can read as a small number after a large failure, which is precisely the situation where the number must be trustworthy.

**Ingress:** `cnt_frames_rx`, `cnt_msgs_rx`, `cnt_msgs_filtered`, `cnt_msgs_accepted`
**Errors:** `err_fcs`, `err_ethertype`, `err_ip`, `err_udp_port`, `err_frame_len`, `err_msg_type`, `err_flags`, `err_signal_conflict`
**Feed health:** `cnt_seq_gap`, `cnt_seq_dup`, `cnt_crossed`, `cnt_book_clear`, `cnt_trades`, `cnt_heartbeats`
**Signal:** `cnt_signal_buy`, `cnt_signal_sell`
**Risk (one per gate):** `cnt_rej_kill`, `cnt_rej_size`, `cnt_rej_position`, `cnt_rej_band`, `cnt_rej_stale`, `cnt_rej_seqgap`, `cnt_rej_crossed`, `cnt_rej_throttle`
**Egress:** `cnt_orders_tx`, `cnt_order_overflow`
**Latency:** `lat_min`, `lat_max`, `lat_last`, plus the 64-bucket histogram

An invariant that must hold at all times and should be asserted in the testbench:

```
cnt_msgs_rx = cnt_msgs_filtered + cnt_msgs_accepted + (all err_* message-level counters)
cnt_signal_buy + cnt_signal_sell = cnt_orders_tx + Σ(cnt_rej_*) + cnt_order_overflow
```

Counter conservation of this kind is a cheap and unusually effective way to catch datapath bugs, because a message that vanishes silently shows up immediately as an arithmetic mismatch.

---

## 11. Verification Plan

### 11.1 Golden model

`sim/golden_model.py` implements the entire specification in Python using only integer arithmetic. It consumes the same stimulus file the RTL testbench consumes and produces the expected order stream and final counter values.

The model is written **from this specification, not from the RTL**, and ideally before the corresponding RTL. A model derived by reading the RTL cannot detect a misreading of the spec — it can only confirm that the RTL does what the RTL does.

### 11.2 Stimulus generation

`sim/feed_gen.py` produces both live UDP traffic and offline hex files, with configurable scenario mixes:

- `--scenario normal` — well-formed random walk, both sides always valid
- `--scenario sparse` — long gaps between updates, exercises the staleness gate
- `--scenario crossed` — deliberately injects crossed books
- `--scenario gaps` — drops and duplicates sequence numbers
- `--scenario malformed` — bad lengths, bad types, reserved flags set
- `--scenario burst` — maximum-density back-to-back frames at line rate
- `--scenario trigger` — tuned to fire the signal at a known, countable rate
- `--seed N` — reproducible; the seed is recorded in every results file

### 11.3 Testbench structure

`tb/tb_top.v`, Verilog with file I/O (`$readmemh`, `$fscanf`), self-checking. It reads stimulus, drives the GMII-side interface, captures the order stream, and compares against the golden model's expected output byte for byte. Any mismatch prints the message index, expected value, actual value, and the current book state, then fails. The testbench exits non-zero on failure so it can gate CI.

### 11.4 Directed test list

Each test maps to requirements and must be individually runnable.

| Test | Covers | Description |
| :-- | :-- | :-- |
| `T01_smoke` | FR-1,4,14 | One frame, one message, book updates correctly |
| `T02_packed` | FR-4,6 | 88 messages in one frame, all parsed in order |
| `T03_back_to_back` | FR-6, NFR-4 | Minimum IFG for 10,000 frames, zero loss |
| `T04_filter` | FR-7 | Mixed symbols; only watched ones affect state |
| `T05_bad_length` | FR-5 | Payload of 17, 15, 0 bytes; clean recovery each time |
| `T06_bad_type` | FR-8,9 | Undefined types, reserved flags set |
| `T07_ipv4` | FR-3 | Mode 1: bad checksum, wrong port, IHL≠5, correct frame |
| `T08_seq_gap` | FR-10,12 | Gap injected, gate `0x06` blocks, snapshot clears |
| `T09_seq_dup` | FR-11 | Duplicate and reordered seq; book unchanged |
| `T10_qty_zero` | FR-15 | Zero-quantity update invalidates the side |
| `T11_book_clear` | FR-16 | Clear message, then repopulate |
| `T12_crossed` | FR-17, gate `0x07` | Crossed book detected and blocks |
| `T13_signal_buy` | FR-20,23 | Exact threshold: spread == min, one below, one above |
| `T14_signal_sell` | FR-21,23 | Mirror of T13 |
| `T15_gate_size` | gate `0x02` | Order size at, below, and above the limit |
| `T16_gate_position` | gate `0x03` | Walk position to the limit and one beyond, both directions |
| `T17_gate_band` | gate `0x04` | Order price exactly at the band edge and one tick outside |
| `T18_gate_stale` | gate `0x05` | Silence past `MAX_AGE`, then a fresh update |
| `T19_gate_throttle` | gate `0x08` | Burst empties the bucket; verify refill rate |
| `T20_kill` | FR-31,32 | Assert mid-stream; verify latch, verify CSR clear required |
| `T21_multi_gate` | FR-28 | Two gates fire together; check reason priority and both counters |
| `T22_overflow` | §6.5 | Force three orders inside one TX window |
| `T23_reset` | FR-18 | Reset mid-stream; verify no stale state survives |
| `T24_csr` | FR-42 | Write every register, read back, verify effect on next message |
| `T25_latency` | NFR-1,2 | Verify histogram has exactly one occupied bucket |
| `T26_soak` | all | 1,000,000 random messages, full output and counter comparison |

### 11.5 Coverage goals

Not formal functional coverage — that would need SystemVerilog — but a checklist the testbench asserts and reports at the end of the soak run:

- Every FSM state reached at least once
- Every risk gate rejected at least one order
- Both signal directions fired
- Every error counter incremented at least once
- Every `msg_type` exercised
- Every symbol slot used
- Counter conservation invariants (§10) hold at the end of every test

### 11.6 Hardware validation

Simulation passing is necessary but not sufficient; the claims in §1.5 are about hardware.

1. Loopback: host sends a known 1,000-message file, receives orders, compares against the golden model output. Byte-exact match required.
2. Line-rate soak: 10 minutes of maximum-density traffic; verify `cnt_msgs_rx` equals the host's transmitted count exactly and `cnt_order_overflow` behaves as predicted.
3. ILA capture of the fast path showing ingress and egress timestamps on the same trigger.
4. Oscilloscope measurement across the RJ45 pins for a true wire-to-wire figure, with GPIO toggles at the ingress and egress timestamp points as an intermediate reference.
5. Kill switch pressed physically mid-soak; verify orders cease and the LED asserts.

---

## 12. Results to Publish

### 12.1 Latency table

| Metric | Cycles | ns @125 MHz |
| :-- | --: | --: |
| Parser ingress → book updated | | |
| Book → signal decision | | |
| Signal → risk verdict | | |
| Risk → first order byte to MAC | | |
| **Engine total (tick-to-trade)** | | |
| MAC RX contribution | | |
| MAC TX contribution | | |
| **Wire-to-wire** | | |

Report min, median, p99, and max for each. The p99 and max being equal to the min is the actual result being claimed.

### 12.2 Utilization

LUT, FF, BRAM, DSP, per module and total, from the post-implementation report, with the percentage of the XC7A35T's 20,800 LUTs / 41,600 FFs / 50 BRAM36 / 90 DSPs.

### 12.3 Timing

WNS, TNS, achieved Fmax, and the top five critical paths with a sentence on each explaining what limits it. A critical path you can explain is worth more in an interview than a slack number you cannot.

---

## 13. Deliverables and Repository Layout

```
fpga-top-of-book-engine/
├── README.md                  # architecture, feed format, how to reproduce, results
├── docs/
│   ├── spec.md                # this document
│   ├── block_diagram.svg
│   ├── latency_budget.md
│   └── design_decisions.md    # every "why not X" answered
├── rtl/
│   ├── tob_top.v
│   ├── frame_classifier.v
│   ├── md_parser.v
│   ├── symbol_filter.v
│   ├── seq_monitor.v
│   ├── tob_engine.v
│   ├── signal_engine.v
│   ├── risk_engine.v
│   ├── order_builder.v
│   ├── latency_histogram.v
│   ├── csr_block.v
│   └── common/                # sync_2ff.v, counter_sat.v, ...
├── tb/
│   ├── tb_top.v
│   ├── tb_<module>.v          # one per module
│   └── stimulus/
├── sim/
│   ├── golden_model.py
│   ├── feed_gen.py
│   ├── order_rx.py
│   └── compare.py
├── constraints/
│   ├── tob_pins.xdc
│   └── tob_timing.xdc
├── scripts/
│   ├── build.tcl              # headless Vivado build
│   ├── run_sim.sh             # all tests, exits non-zero on failure
│   └── report.py              # parses Vivado reports into markdown tables
├── results/
│   ├── utilization.md
│   ├── timing.md
│   ├── latency_histogram.csv
│   └── ila_captures/
└── Makefile                   # make sim / make synth / make bit / make all
```

The README is a deliverable in its own right and should contain: the block diagram, the message format table, the decision rule stated in one line, the risk gate table, the reproduction commands, the results tables, and — explicitly — the modelling assumptions from §4.3 and §8.3. Stating limitations plainly reads as engineering judgement; leaving them for a reviewer to discover reads as something else.

---

## 14. Extensions (Explicitly Out of Scope for v1)

Listed so that "not implemented" is visibly a decision rather than an oversight.

1. **Multi-level order book.** Eight price levels per side in BRAM with add/modify/cancel semantics, requiring a new-best search when the top level is removed. This is the single largest step toward realism and the natural v2.
2. **A/B feed arbitration.** Real feeds are broadcast twice on separate paths; the receiver takes whichever copy of each sequence number arrives first. Genuinely useful, and a good use of the second symbol slot infrastructure.
3. **Real exchange protocol decode.** A subset of NASDAQ ITCH 5.0 — variable-length, big-endian, with actual message types. Replaces the synthetic format with something recognizable to a practitioner.
4. **Probabilistic fill model.** Seeded PRNG shared with the golden model, partial fills, queue position estimation.
5. **Wider datapath.** 64-bit at 125 MHz for a 10G-capable core, exercising NFR-5.
6. **Order entry protocol.** A simplified OUCH-style encoder rather than a bare record.
7. **Softcore control plane.** MicroBlaze for configuration and stats, replacing the CSR frames.

---

## 15. Milestone Plan

Ten working days with a review gate at the end of each stage. Nothing proceeds past a gate with a failing test.

| Stage | Days | Work | Gate |
| :-- | :-- | :-- | :-- |
| **S0 — Scaffold** | 0.5 | Repo, Makefile, Vivado project scripted, empty top builds | `make all` produces a bitstream from an empty design |
| **S1 — Format and model** | 1 | Message format frozen, `feed_gen.py` and `golden_model.py` written and cross-checked | Golden model produces expected orders for a hand-computed 20-message case |
| **S2 — Parser** | 1.5 | `frame_classifier`, `md_parser`, module testbenches | T01, T02, T05, T06 pass; 1M-message parse with zero loss |
| **S3 — Book** | 1 | `symbol_filter`, `seq_monitor`, `tob_engine` | T04, T08–T12 pass |
| **S4 — Signal** | 0.5 | `signal_engine` | T13, T14 pass, including exact-threshold cases |
| **S5 — Risk** | 1.5 | `risk_engine`, all eight gates, position, throttle | T15–T21 pass; every gate counter provably incremented |
| **S6 — Egress** | 1 | `order_builder`, framing, IPv4 checksum, MAC TX integration | Order frames captured and decoded correctly by `order_rx.py` |
| **S7 — Instrumentation** | 1 | Timestamps, histogram, counters, CSR, stats frames | T24, T25 pass; histogram single-bucket in simulation |
| **S8 — Integration** | 1 | Full soak, timing closure at 125 MHz, utilization | T26 passes; WNS > 0; NFR-7 met |
| **S9 — Hardware** | 1.5 | Board bring-up, loopback, line-rate soak, ILA, scope, kill switch | All of §11.6 demonstrated |
| **S10 — Publish** | 0.5 | README, diagrams, results tables, demo video | A clean clone reproduces the simulation results |

**Fallback if the MAC is not ready at S6.** The engine's interface to the MAC is a plain 8-bit ready/valid stream, so the MAC is replaceable without touching the engine. If the MAC blocks progress, S6 proceeds against a testbench stream driver, and S9 uses the UART ingress (FR-43) for a functional hardware demo while Ethernet integration continues in parallel. Latency claims in that case are simulation-plus-ILA rather than wire-to-wire, and the README must say which. Building the ingress abstraction on day one is what makes this fallback cheap.

---

## 16. Risks to the Project

| Risk | Impact | Mitigation |
| :-- | :-- | :-- |
| MAC not production-ready | Blocks S6/S9 | Abstracted ingress interface; UART fallback; MAC is on the critical path only for the wire-to-wire number |
| RGMII timing on KSZ9031RNX | Bring-up delay | Bring up the ALINX Ethernet example first and confirm the board's RX/TX clock skew configuration before integrating |
| Scope creep into a real order book | Schedule loss | §14 exists precisely to hold the line; multi-level book is v2 |
| Golden model written from RTL | Verification is worthless | Write the model at S1, before the corresponding RTL |
| Timing closure at 125 MHz | Late rework | The imbalance shifter and the register-file mux are the known suspects; keep `IMB_SHIFT` ≤ 3 and `NUM_SYMBOLS` = 4 |
| Latency histogram shows spread | Undermines the headline claim | Treat any second occupied bucket as a functional bug at S7, not a tuning problem at S10 |

---

## 17. Open Questions

To resolve before or during S0:

1. **MAC interface shape.** Does the existing MAC present a plain 8-bit valid/last stream, or a full AXI4-Stream with `tkeep` and `tready`? The adapter is trivial either way, but S2's testbench should drive the real shape from the start.
2. **MAC RX error signalling.** Does it deliver a frame with an error flag after the fact, or suppress the frame entirely? This determines whether `frame_classifier` needs a discard-in-flight path.
3. **`LINK_MODE` at bring-up.** Start in raw-Ethernet mode and add IPv4 at S6, or commit to UDP from S2? Raw first is lower-risk; UDP from the start avoids writing the classifier twice.
4. **Board keys.** The AX7035B has two user keys where the AX7035 has four — confirm which variant is in hand, since the kill switch, counter clear, and mode select all want buttons.
5. **Reject reporting.** Is `msg_type 0x11` diagnostic output wanted at all, or are counters sufficient? It is useful during bring-up and arguably noise afterward.
