# Latency Budget

Cycle-by-cycle accounting of the tick-to-trade path, derived from the RTL as
it stands. Master spec §13 lists this file as a deliverable; §7.1 states the
requirement (NFR-1/2) it exists to make auditable.

**This document contains no measured numbers.** Per the master spec's own
convention, measured latency/utilization/slack values live only in §12 and in
`results/`. Everything below is a *structural* property — pipeline depth is a
fact about the circuit, readable from the RTL, and is what makes the measured
single-bucket histogram (NFR-2) predictable rather than surprising.

Every depth cited is traceable to a named construct in the RTL. When a stage
depth changes, this file and the three derived constants in §4 must change
with it — §5 is the checklist for that, and exists because this project has
already shipped three separate bugs (D25, D28, and the `ml_policy` fail-safe
snapshot) caused by one stage's depth changing while a constant derived from
it did not.

---

## 1. Timestamp points

| Point | Definition | Where |
| :-- | :-- | :-- |
| **Ingress** | The cycle `md_parser.v` completes a message (`complete_d`, the cycle after byte 15 lands) — FR-53's "last byte of a message entering the parser" | `rtl/md_parser.v`, `complete_d` |
| **Egress** | The cycle `order_builder.v` hands a record to `eth_mac_if.v` (`tx_start`) — FR-54's "first byte handed to MAC TX" | `rtl/order_builder.v`, `pop_this_cycle` |

`latency_cyc` in the emitted order record is `cur_cycle − ingress_captured`,
computed live at pop time, so a record that waited behind a busy TX reports
its real wait rather than a frozen nominal value (`rtl/order_builder.v`,
`lat_diff`).

Call the ingress cycle **T0**. `tob_engine.v`'s front-end register (D36) makes
`book_upd_valid` fire at **T = T0 + 1**; every module below documents its own
latency relative to `book_upd_valid`, so the table uses **T**.

---

## 2. Pre-engine ingress (outside the measured window)

Not part of the fixed tick-to-trade count, and deliberately not budgeted here:

- **Vendor MAC RX** buffers the *whole* frame and verifies FCS + IPv4 header
  checksum before asserting `udp_rec_data_valid` (D1). Its contribution is a
  function of frame length, not of engine design.
- **`eth_mac_if.v`** walks the RX RAM address counter — present an address,
  capture the registered response one cycle later (D10) — re-presenting bytes
  as a stream.
- **`frame_classifier.v`** checks `rx_len` at `frame_start` and decides before
  forwarding a byte (D11). Combinational; adds no cycles.
- **`md_parser.v`** is byte-serial: a 16-byte message occupies 16 cycles on the
  wire regardless of pipeline depth. This is what sets the sustained message
  rate (NFR-4), not the latency.

Wire-to-wire latency including the MAC (NFR-3) is an S11 measurement, not a
derivation. It is not in this file.

---

## 3. The engine — fixed tick-to-trade path

Two branches run in parallel after the book update and converge at the risk
engine. **The ML branch is the deeper one and therefore sets the total.**

### 3.1 Signal branch

| Lands at | Stage | Source |
| :-- | :-- | :-- |
| T0 | `md_parser` → `msg_valid` | `rtl/md_parser.v` |
| T0 | `symbol_filter` → `filt_valid`/`filt_slot` (combinational, no registers) | `rtl/symbol_filter.v` |
| **T = T0+1** | `tob_engine` front-end register → `msg_applied`/`book_upd_valid`/`applied_slot` (**D36**, +1) | `rtl/tob_engine.v`, `p_filt_valid` |
| T+2 | `signal_engine` → `sig_valid` (**D40**, 2 stages: registers the post-update book, then decides) | `rtl/signal_engine.v` |
| T+6 | `delay_line` alignment → `sig_valid_aligned` (`ALIGN_DEPTH = 4`) | `rtl/tob_top.v`, `u_align` |
| **T+8 = T0+9** | `risk_engine` → `order_valid`/`reject_reason` (**D34**, 2 stages: gates, then reason-mux + accept) | `rtl/risk_engine.v` |

### 3.2 ML branch

| Lands at | Stage | Source |
| :-- | :-- | :-- |
| T+3 | `feature_extractor` → `feat_valid` (**D26/D27 v2**, 3 stages: wide sums → F1/\|F1\|/F3 → incremental F5/F7) | `rtl/feature_extractor.v` |
| T+4 | `feature_normalizer` → `norm_valid` | `rtl/feature_normalizer.v` |
| T+5 | `ml_classifier_wrap` → `ml_valid`/`z` | `rtl/ml_classifier_wrap.v` |
| **T+6** | `ml_policy` → `adverse_risk` | `rtl/ml_policy.v` |

### 3.3 Convergence

Both branches present at the risk engine on **T+6**:

```
signal branch : book_upd_valid ─2─► sig_valid ─ALIGN_DEPTH(4)─► T+6
ML branch     : book_upd_valid ─────────6─────────────────────► T+6
                                                                 │
                                                     risk_engine ─2─► T+8
```

This is the structural claim behind NFR-1/2: the verdict and the intent meet
in the same cycle **by construction**, not by arbitration, so the total is a
compile-time constant and the histogram occupies one bucket.

---

## 4. Derived constants — the drift-prone part

Three constants encode the relationships above. Each has exactly one source of
truth; none may be hand-copied.

| Constant | Value | Identity | Defined in |
| :-- | --: | :-- | :-- |
| `ALIGN_DEPTH` | 4 | `ML_branch_total(6) − signal_branch(2)` | `rtl/tob_top.v` localparam |
| `SNAPSHOT_DEPTH` | 4 | `ml_valid_offset(5) − snapshot_capture_offset(1)` | `rtl/ml_policy.v` parameter |
| `TRIGGER_DELAY` | 9 | `D36(1) + signal(2) + ALIGN_DEPTH(4) + risk(2)` | `rtl/tob_top.v`, passed to `u_ob` as `5 + ALIGN_DEPTH` |

**`ALIGN_DEPTH` and `SNAPSHOT_DEPTH` are numerically equal today and must not
be wired together.** They derive from different relationships: `ALIGN_DEPTH`
involves `signal_engine`'s latency, `SNAPSHOT_DEPTH` does not. If
`signal_engine` ever gains or loses a stage, `ALIGN_DEPTH` moves and
`SNAPSHOT_DEPTH` does not. `tb/tb_ml_policy.v` instantiates `ml_policy` with a
deliberately *different* depth so a "reuse `ALIGN_DEPTH`" wiring mistake cannot
pass by coincidence.

`TRIGGER_DELAY` is supplied from the same `ALIGN_DEPTH` localparam rather than
being written out as a literal — the D25 fix — so the two cannot drift apart
silently.

---

## 5. Checklist when any stage depth changes

Reopening one of these depths has broken a downstream constant three times.
Work the whole list:

1. **`ALIGN_DEPTH`** — recompute as `ML_branch_total − signal_branch`. The two
   branches must still converge on the same cycle.
2. **`TRIGGER_DELAY`** — recompute as the full `msg_valid → order_valid`
   latency. Wrong here means `trigger_seq` attributes orders to the wrong
   message and `latency_cyc` is measured against the wrong timestamp — and a
   *fixed* wrong offset still produces a single histogram bucket, so NFR-2
   will not catch it (D25).
3. **`SNAPSHOT_DEPTH`** (`ml_policy`) — recompute as `ml_valid_offset − 1`.
   Wrong here means the ML fail-safe judges a different message's book state.
4. **`risk_engine`'s internal book/staleness snapshot** — keyed to
   `ALIGN_DEPTH`; gates `0x04`/`0x05`/`0x07` read per-message state that must
   be captured at T+1, not read live (D28).
5. **Per-module testbench pipeline offsets** — `tb_feature_extractor`,
   `tb_feature_tob_chain`, `tb_ml_chain`, `tb_tob_top` all encode explicit
   cycle waits.
6. **This file**, plus the affected module headers.

A standing guard exists for item 3: `tb/tb_ml_chain.v` asserts that
`ml_policy`'s internal `fs_snap_out_valid` coincides with `ml_valid` on every
cycle. Because that testbench instantiates the *real*
`feature_extractor → feature_normalizer → ml_classifier_wrap` chain, a latency
change anywhere in it breaks the assertion immediately. The equivalent check
inside `tb/tb_ml_policy.v` cannot serve this purpose — that testbench contains
none of those three modules and generates `ml_valid` from `SNAPSHOT_DEPTH`
itself, so both sides move together.

---

## 6. Egress

| Step | Behaviour | Source |
| :-- | :-- | :-- |
| Queue | 2-deep record register, not a FIFO. A third record while two are pending is dropped with `cnt_order_overflow` (§7.5) — bounded by design so latency cannot become history-dependent | `rtl/order_builder.v`, `q0`/`q1` |
| Pop | Requires the queue non-empty and `~tx_busy & ~tx_start`; a record pushed at T+8 pops no earlier than T+9 | `rtl/order_builder.v`, `pop_this_cycle` |
| TX pacing | `eth_mac_if.v` holds payload byte 0 until exactly `TX_HEADER_DELAY = 9` cycles after `udp_tx_req`, matching the vendor `udp_tx.v` checksum FSM's sampling offset (D10 — derived by hand, then verified against the real vendor logic, not assumed) | `rtl/eth_mac_if.v` |

An order frame occupies TX for roughly the frame duration; the signal can fire
again inside that window, which is precisely what the 2-deep queue and the
overflow counter bound.

---

## 7. How these depths got here

The path has been re-pipelined repeatedly for timing closure. Recorded so the
next change is made with the pattern visible rather than rediscovered:

| Entry | Change | Effect on depth |
| :-- | :-- | :-- |
| D24 | S6 ML branch first integrated | `ALIGN_DEPTH` = 3 |
| D25 | `order_builder` trigger pipeline decoupled from a hardcoded 2 | `TRIGGER_DELAY` becomes derived |
| D26/D27 | `feature_extractor` re-pipelined to 3 stages (v1 misdiagnosed, v2 fixed) | ML branch 4 → 6 |
| D34 | `risk_engine` split into 2 stages | `TRIGGER_DELAY` +1 |
| D36 | `tob_engine` front-end register | everything +1 from T0 |
| D40 | `signal_engine` split into 2 stages | signal branch 1 → 2, `ALIGN_DEPTH` 5 → 4 |

The recurring lesson: **a change that shortens a combinational path almost
always lengthens a pipeline, and every constant derived from that pipeline has
to be re-derived in the same change** — not in the audit afterwards.
