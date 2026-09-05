# Contract: `rtl/order_builder.v`

Status: ready to hand off, but **read all of §1 and §2 first** — this
module has to solve a real architectural gap none of the prior S3/S5/S7
modules addressed (§1.2), and gets the queueing/backpressure behavior
(§2.4) that every earlier module's contract explicitly deferred to "S8."
Depends on `rtl/risk_engine.v` (S7, committed), `rtl/eth_mac_if.v` (already
built — its TX interface, §1.3, is fixed and not something this contract
can change), and `rtl/md_parser.v` (S2, committed).

## 1. Background

### 1.1 What this module does

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain). `order_builder.v` is the master spec's egress block (§3.1
block `[J]`, §4.5, FR-49..52): it takes `risk_engine.v`'s accept/reject
decision, encodes it into the 16-byte order-record wire format, and drives
it out through `eth_mac_if.v`'s TX interface — handling the case where a
second (or third) order arrives before the first has finished transmitting.

### 1.2 The gap this contract has to close: `trigger_seq` and `symbol_id`

**No module built so far carries a triggering message's `seq_num` or raw
8-bit `symbol_id` past `md_parser.v`.** `symbol_filter.v` reduces a message
to a 2-bit *slot* index; `tob_engine.v`, `signal_engine.v`, and
`risk_engine.v` all propagate `slot`, never the original `symbol_id` or
`seq_num`. The wire format (§4.5) needs both: `symbol_id` (the actual
8-bit watched-symbol value) and `trigger_seq` (the low 16 bits of the
triggering message's `seq_num`). This was flagged as an explicit
out-of-scope item in every S3/S5/S7 contract, deferred to "whichever module
needs it, likely `order_builder.v`, S8" — that's now.

**Resolved two different ways, deliberately not the same way:**

- **`symbol_id`** doesn't need to travel through the pipeline at all —
  `slot → symbol_id` is a static config lookup (the same `cfg_symbol_0..3`
  registers `symbol_filter.v` already uses), evaluated combinationally
  against `order_slot` at the moment it's needed. No pipelining required.
- **`trigger_seq`** is genuinely per-message data that has to ride along
  with the rest of the order intent through `signal_engine.v`'s and
  `risk_engine.v`'s two registered pipeline stages. `order_builder.v` reads
  `md_parser.v`'s `msg_seq_num` directly and runs its own small,
  **unconditional** two-stage shift register alongside the rest of the
  pipeline — see §2.2 for why unconditional (not gated on `msg_valid`) is
  both correct and simpler.

### 1.3 `eth_mac_if.v`'s TX interface (already built, fixed)

```verilog
input  wire [127:0] tx_payload,  // byte 0 in bits [127:120], byte 15 in [7:0]
input  wire         tx_start,    // one-shot pulse; ignored while tx_busy
output wire         tx_busy,     // high from tx_start until the frame is sent
```

Per `rtl/eth_mac_if.v`'s own header comment: "order_builder only ever sees
tx_payload/tx_start/tx_busy: present the payload, pulse tx_start, wait for
tx_busy to drop." **`tx_busy` lags `tx_start` by one cycle** —
`eth_mac_if.v`'s internal FSM samples `tx_start` on a clock edge and only
*then* transitions out of its idle state, so `tx_busy` reads `0` during the
exact cycle `tx_start` is high, not yet reflecting the transfer that just
started. §2.5 explains why this matters for avoiding a double-issued
`tx_start`.

## 2. What you're building

**File:** `rtl/order_builder.v`
**Testbench:** `tb/tb_order_builder.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module order_builder (
    input  wire        clk,
    input  wire        rst_n,   // active-low; same reset style as the rest
                                 // of this repo

    // from md_parser.v -- source for the trigger_seq pipeline (S2.2). Only
    // msg_seq_num is needed; it's a stable, held register between updates
    // (docs/contracts/md_parser.md), so no msg_valid gating is needed here.
    input  wire [31:0] msg_seq_num,

    // from risk_engine.v -- one decision per evaluated intent. reject_reason
    // is nonzero on exactly the cycles order_valid is 0 AND a gate actually
    // fired (never both order_valid=1 and reject_reason!=0 the same cycle --
    // risk_engine.v's own accepted_c construction guarantees this).
    input  wire        order_valid,
    input  wire [1:0]  order_slot,
    input  wire [7:0]  order_side,
    input  wire [31:0] order_price,
    input  wire [31:0] order_qty,
    input  wire [7:0]  reject_reason,

    // free-running cycle counter -- the SAME one risk_engine.v takes
    // (docs/contracts/risk_engine.md), for latency_cyc (S2.3)
    input  wire [31:0] cur_cycle,

    // config: slot -> symbol_id lookup (S9 SYMBOL_0..3), same four
    // registers symbol_filter.v already reads. Direct ports, standing in
    // for csr_block.v, same pattern as every other module.
    input  wire [7:0]  cfg_symbol_0,
    input  wire [7:0]  cfg_symbol_1,
    input  wire [7:0]  cfg_symbol_2,
    input  wire [7:0]  cfg_symbol_3,

    // config: FR-44/D7 -- 0x11 reject frames are opt-in, off by default
    input  wire        cfg_reject_report,

    // to eth_mac_if.v (S1.3, fixed interface)
    output reg  [127:0] tx_payload,
    output reg           tx_start,
    input  wire           tx_busy,

    // status: one-cycle pulse per record dropped because both queue slots
    // were already occupied (S2.4)
    output wire         cnt_order_overflow_pulse
);
```

### 2.2 The `trigger_seq` pipeline

Two-stage, **unconditional** (ticks every cycle, no enable):

```verilog
reg [15:0] seq_d0, seq_d1;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        seq_d0 <= 16'd0;
        seq_d1 <= 16'd0;
    end else begin
        seq_d0 <= msg_seq_num[15:0];
        seq_d1 <= seq_d0;
    end
end
```

**Why unconditional, not gated on some "a message arrived" signal:**
`msg_seq_num` already holds its last-decoded value between updates (it's a
plain register in `md_parser.v`, never cleared except at reset). The total
registered latency from `md_parser.v`'s `msg_valid` pulse (for a given
triggering message) to `risk_engine.v`'s matching `order_valid`/
`reject_reason` is **exactly two cycles** — `symbol_filter.v`/
`seq_monitor.v`/`tob_engine.v` are all purely combinational
(`docs/contracts/symbol_filter.md`, `docs/contracts/seq_monitor.md`,
`docs/contracts/tob_engine.md`), so `msg_applied`/`book_upd_valid` land on
`md_parser.v`'s own `msg_valid` cycle; `signal_engine.v` registers one cycle
later; `risk_engine.v` registers one cycle after that. A plain two-stage
shift register that runs every cycle therefore holds, two cycles later,
*exactly* the `seq_num` that was live at `md_parser.v`'s `msg_valid` pulse
for whichever message is now producing `order_valid`/`reject_reason` — no
explicit "is this the same message" tracking needed, the alignment is
automatic by construction (same reasoning `risk_engine.v`'s own D17
`pend_prev_cycle`/`pend_msg_cycle` pipeline already relies on — see
`docs/contracts/risk_engine.md` §2.4 if this reasoning looks unfamiliar).
`seq_d1` is what feeds `trigger_seq` when a record is pushed (§2.4).

### 2.3 `symbol_id` lookup and `latency_cyc`

```verilog
wire [7:0] sym_id_c = (order_slot == 2'd0) ? cfg_symbol_0 :
                      (order_slot == 2'd1) ? cfg_symbol_1 :
                      (order_slot == 2'd2) ? cfg_symbol_2 : cfg_symbol_3;
```

Pure combinational config lookup — no pipelining needed (§1.2).

`latency_cyc` is **not** computed at push time. `ingress_cycle`
(`cur_cycle` as it read at `md_parser.v`'s `msg_valid` pulse, pipelined the
same two cycles as `trigger_seq`, same reasoning) is stored **as part of
the queued record** (§2.4), and `latency_cyc = cur_cycle_at_pop -
ingress_cycle` is computed live at the moment the record is actually
handed to `eth_mac_if.v` (§2.5) — this correctly reflects FR-53/54's
"ingress timestamp to egress timestamp (first byte handed to MAC TX)"
definition even when a record had to wait in the queue behind an
in-progress transmission, which a latency value frozen at push time would
not.

### 2.4 The 2-deep record queue (FR-49/50/51/52, §7.5)

**A record is *not* transmitted the instant `order_valid`/`reject_reason`
fires — `eth_mac_if.v` might still be draining a previous one.** This is
exactly the gap every S3/S5/S7 contract deferred with "TX-slot pacing is
`order_builder.v`'s job" (e.g. `docs/contracts/risk_engine.md` §1's third
bullet). `sim/golden_model.py` models this as up to two pending
transmissions in flight at once, with a third dropped
(`cnt_order_overflow`) — this module mirrors that structural invariant
with two explicit record registers (not a generic parameterized FIFO; two
is a fixed, spec-given depth, not a tunable):

```verilog
reg [143:0] q0, q1;   // {msg_type, symbol_id, side, reject_reason, price,
                       //  qty, trigger_seq, ingress_cycle} -- 8+8+8+8+32+
                       //  32+16+32 = 144 bits. q0 is always the OLDEST
                       //  (next to transmit); q1 the newer one.
reg [1:0] q_count;    // 0, 1, or 2 occupied
```

**Push decision**, evaluated combinationally every cycle from
`risk_engine.v`'s outputs:

```verilog
wire want_push = order_valid | (cfg_reject_report & (reject_reason != 8'd0));
wire [7:0] push_msg_type = order_valid ? 8'h10 : 8'h11;   // NEW : REJECT
```

(`order_valid` and a nonzero `reject_reason` are mutually exclusive the
same cycle — §2.1 — so `push_msg_type`'s selection is unambiguous.)

**Overflow and simultaneous push+pop:** a pop (§2.5) can happen the *same*
cycle as a push — draining one record frees a slot the incoming one can
use immediately, matching `sim/golden_model.py`'s own `_retire_tx_slots`
running *before* its overflow check. Compute the effective occupancy
*after* this cycle's pop before deciding overflow:

```verilog
wire pop_this_cycle = /* S2.5: true when a record is being popped now */;
wire [1:0] count_after_pop = q_count - (pop_this_cycle ? 2'd1 : 2'd0);
wire overflow = want_push & (count_after_pop >= 2'd2);
assign cnt_order_overflow_pulse = overflow;
```

On a cycle where `want_push` and `!overflow`: shift `q0`'s old contents out
(if a pop is *also* happening this cycle, `q0` is already being drained —
see §2.5 for how push and pop combine into one coherent next-state update
for `q0`/`q1`/`q_count`, same "single next-state expression, never two
separate non-blocking writes to the same register" discipline as
`risk_engine.v`'s token bucket, `docs/contracts/risk_engine.md` §2.3) and
push the new record into the newly-open slot; `q_count` increments (net of
any same-cycle pop).

### 2.5 Draining the queue into `eth_mac_if.v`

```verilog
wire pop_this_cycle = (q_count != 2'd0) & ~tx_busy & ~tx_start;
```

**The `~tx_start` term is not optional — this is the one real footgun in
this module, read it before implementing.** `tx_busy` lags `tx_start` by
one cycle (§1.3): on the cycle `tx_start` is high, `tx_busy` still reads
`0` (it hasn't caught up yet). A naive `pop_this_cycle = (q_count != 0) &
~tx_busy` would therefore stay true for **two** consecutive cycles after a
pop — the cycle `tx_start` fires (where `tx_busy` is still `0`) and would
try to pop *again* before `eth_mac_if.v` has had a chance to register that
it's now busy, corrupting the queue and double-transmitting. Gating on
`~tx_start` as well (don't start a new transfer on the cycle immediately
following a `tx_start` pulse) closes this — verified by tracing
`eth_mac_if.v`'s actual FSM (`tx_busy = (tx_state != TX_IDLE)`, and
`tx_state` only leaves `TX_IDLE` on the edge *after* `tx_start` is sampled)
rather than assumed.

On `pop_this_cycle`: dequeue `q0` (`q1`'s contents shift down to `q0` if
`q_count` was 2, else `q0` becomes don't-care and `q_count` becomes 0),
register `tx_start <= 1'b1`, and register `tx_payload` from `q0`'s stored
fields **plus the live latency computed now**:

```verilog
tx_payload <= { q0_msg_type, q0_symbol_id, q0_side, q0_reject_reason,
                q0_price, q0_qty, q0_trigger_seq,
                (cur_cycle - q0_ingress_cycle)[15:0] };   // latency_cyc, S2.3
```

On any other cycle, `tx_start <= 1'b0` (a one-shot pulse, exactly one cycle
per popped record, per §2.5's `~tx_start` self-gating).

### 2.6 Wire encoding (§4.5)

16 bytes, big-endian, matching `sim/golden_model.py`'s `OrderRecord.encode()`
exactly (`>BBBBIIHH`): `msg_type`(1) `symbol_id`(1) `side`(1)
`reject_reason`(1) `price`(4, MSB-first) `quantity`(4, MSB-first)
`trigger_seq`(2, MSB-first) `latency_cyc`(2, MSB-first). `tx_payload`'s
byte-0-in-MSBs convention (§1.3) means a plain concatenation of the
full-width scalar fields already produces the correct big-endian byte
order on the wire — no manual byte-swapping needed, since each field's own
bit 31 (or bit 15, bit 7) is already its most-significant bit.

## 3. Testbench requirements (`tb/tb_order_builder.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o order_builder_tb.vvp rtl/order_builder.v tb/tb_order_builder.v && vvp order_builder_tb.vvp`),
no manual waveform inspection. Drive `msg_seq_num`/`order_*`/`reject_reason`/
`cur_cycle`/`cfg_*`/`tx_busy` directly (no need to instantiate
`risk_engine.v`/`md_parser.v`/`eth_mac_if.v` — model `tx_busy` yourself with
a small behavioral stand-in that asserts one cycle after `tx_start` and
deasserts after a chosen number of cycles, mirroring `eth_mac_if.v`'s
documented one-cycle lag). Cover, at minimum:

- **Single accepted order, no backpressure:** drive `msg_seq_num` before an
  `order_valid` pulse (two cycles ahead, per §2.2's exact alignment),
  confirm `tx_payload` decodes to the correct 16 bytes (`msg_type=0x10`,
  correct `symbol_id` via the `cfg_symbol_*` lookup, correct `side`/
  `price`/`qty`/`trigger_seq`), `tx_start` pulses for exactly one cycle,
  and `latency_cyc` matches the actual elapsed `cur_cycle` delta.
- **Rejected intent, `cfg_reject_report=1`:** same shape, `reject_reason`
  nonzero, confirm `msg_type=0x11` and the correct `reject_reason` byte in
  the encoded frame.
- **Rejected intent, `cfg_reject_report=0` (the default, FR-44):** confirm
  **nothing** gets pushed/transmitted — no `tx_start`, `q_count` never
  increments.
- **Queueing:** with `tx_busy` held artificially long (simulating a slow
  drain), push two records in quick succession — confirm both eventually
  transmit, in order (FR-51), each with `latency_cyc` reflecting its own
  actual wait, not a value frozen at push time.
- **Overflow:** with the queue already holding two records (both blocked
  behind a long `tx_busy`), push a third — confirm `cnt_order_overflow_pulse`
  fires and the third record is silently dropped (never transmitted), while
  the first two still drain correctly afterward.
- **Simultaneous push+pop:** engineer a cycle where a pop completes (queue
  was full) and a new push arrives on that exact same cycle — confirm the
  push is accepted (not treated as overflow), per §2.4's `count_after_pop`
  reasoning.
- **The `~tx_start` self-gating footgun, directly (§2.5):** with a
  `tx_busy` stand-in that has the documented one-cycle lag (not an
  idealized same-cycle model — this is the case that would hide the bug),
  confirm exactly one `tx_start` pulse is issued per queued record, never
  two back-to-back for the same record. This is the single most important
  case in this testbench.
- **`trigger_seq`/`symbol_id`/`latency_cyc` alignment across an interleaved
  sequence:** drive several messages with distinct `msg_seq_num` values,
  only some producing `order_valid`, confirm each transmitted record's
  `trigger_seq` corresponds to *its own* triggering message, not a
  neighboring one — this is the case that would catch a pipeline-depth
  miscalculation in §2.2.
- On any mismatch, `$display` what was expected vs. what happened (which
  record, which field, expected vs. actual), then a final `$display("FAIL")`
  / `$display("PASS")` line — this project's plain self-checking-Verilog
  convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o order_builder_tb.vvp rtl/order_builder.v tb/tb_order_builder.v` compiles with zero warnings.
- [ ] `vvp order_builder_tb.vvp` prints `PASS`.
- [ ] `rtl/order_builder.v` is Verilog-2001 only (no SystemVerilog).
- [ ] `tx_start` never double-pulses for a single popped record even against
      a `tx_busy` model with the documented one-cycle lag (§2.5) — this is
      the case most likely to pass against an idealized/same-cycle `tx_busy`
      stand-in and silently fail against real `eth_mac_if.v` timing; the
      testbench's `tx_busy` model must actually reproduce the lag, not
      assume it away.
- [ ] `latency_cyc` is computed at pop time from a stored `ingress_cycle`,
      not frozen at push time (§2.3) — verified by the queueing test case,
      where a delayed record's `latency_cyc` must reflect its actual wait.
- [ ] Overflow only triggers when both queue slots are genuinely occupied
      *after* accounting for any same-cycle pop (§2.4).
- [ ] `cfg_reject_report=0` (default) produces zero transmissions for any
      rejected intent.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Anything about `eth_mac_if.v`'s own TX pacing, UDP checksum timing, or
  RAM/FIFO interaction with the vendored MAC — already built
  (`docs/design_decisions.md` D10), fixed interface, not touched here.
- FR-53/54's full timestamp-carrying/histogram infrastructure — this
  module only computes `latency_cyc` for the *emitted frame's own field*;
  the 64-bucket histogram, `lat_min`/`lat_max`/`lat_last` registers, and
  periodic stats reporting are S9's job.
- Counters that persist `cnt_order_overflow_pulse`'s count — this module
  only emits the raw pulse; a later CSR/counters block owns accumulating
  it, same pattern as every prior module.
- IPv4/UDP header framing for Mode 1 — already handled entirely by
  `eth_mac_if.v`/the vendored MAC (`docs/design_decisions.md` D1); this
  module only ever produces the 16-byte order-record payload.
- A queue depth other than 2 — fixed, matching `sim/golden_model.py`'s own
  structural invariant, not a tunable parameter.
- Runtime CSR wiring for `cfg_symbol_*`/`cfg_reject_report` — direct ports
  for now, same as every other module; `csr_block.v` doesn't exist yet.
