# Contract: fix `signal_engine.v` reading a stale book (patches `rtl/tob_engine.v` + `rtl/signal_engine.v`)

Status: ready to hand off. **Not a new module** — a correctness patch to
two already-committed modules (`rtl/tob_engine.v`, S3, and
`rtl/signal_engine.v`, S5), found while independently verifying
`tob_top.v`'s delivered implementation. Recorded as
`docs/design_decisions.md` D23 — **read D23 in full before this
contract**, it has the complete verification trail (golden-model
comparison, an isolated two-module reproduction) this contract only
summarizes.

## 1. Background

### 1.1 The bug, precisely

`signal_engine.v` evaluates its buy/sell decision from `tob_engine.v`'s
`bid_price`/`ask_price`/`bid_qty`/`ask_qty`/`bid_valid`/`ask_valid`/
`crossed` outputs, gated on `book_upd_valid` — combinationally, on the
*same* cycle the triggering message arrives. But those outputs are wired
only to `tob_engine.v`'s **registered** state
(`assign bid_price = bid_price_r;`, etc.), and a register written with
`<=` on a clock edge isn't visible to another module reading it on that
*same* edge — only starting the next cycle. So `signal_engine.v` sees the
book as it stood **before** the triggering message's own effect, not
after, despite its own header comment explicitly claiming "post-update
state of the applied slot."

**Confirmed against two independent sources (D23):** `sim/golden_model.py`
updates the book, then evaluates `buy_ok`/`sell_ok` in the same function
call — post-update, by construction. And empirically: a bid QUOTE followed
by an ask QUOTE that together satisfy every `buy_ok` condition does not
fire `sig_valid` in the real RTL chained together; a third, redundant
message is needed.

### 1.2 The fix

`tob_engine.v` already computes the applied slot's post-update state
combinationally, internally, for its own crossed-detection logic:

```verilog
wire [31:0] nb_bp = (quote_bid & qty_nz) ? msg_price : s_bp;
wire [31:0] nb_bq = quote_bid            ? msg_quantity : s_bq;
wire        nb_bv = quote_bid            ? qty_nz      : is_clear ? 1'b0 : s_bv;
wire [31:0] nb_ap = (quote_ask & qty_nz) ? msg_price : s_ap;
wire [31:0] nb_aq = quote_ask            ? msg_quantity : s_aq;
wire        nb_av = quote_ask            ? qty_nz      : is_clear ? 1'b0 : s_av;
wire        addr_crossed_next = nb_bv & nb_av & (nb_bp >= nb_ap);
```

It just never exposes them. The fix is additive on `tob_engine.v`'s side
(seven new output ports, zero new logic — §2.1) and a port-list change on
`signal_engine.v`'s side (read the new scalar ports instead of indexing
the registered, per-symbol flattened bus by `applied_slot` — §2.2).

**Why this shape, not a `signal_engine.v`-side pipeline stage:** the
alternative — delay `signal_engine.v`'s own evaluation by a cycle so the
registered bus has caught up — would change its latency and break the
"exactly two registered cycles from `md_parser`'s `msg_valid` to
`risk_engine`'s `order_valid`" invariant `order_builder.v`'s own
`seq_d0`/`seq_d1`/`ingress_d0`/`ingress_d1` pipelines depend on
(`docs/contracts/order_builder.md` §2.2). Exposing already-computed
combinational wires as new ports changes nothing about either module's
timing — `signal_engine.v` still registers its decision exactly one cycle
after `book_upd_valid`, as before.

### 1.3 What this patch does *not* touch, and why

- **`risk_engine.v` is unaffected, confirmed not assumed (D23).** It reads
  `tob_engine.v`'s `crossed`/`bid_price`/`ask_price` at `sig_slot` —
  `signal_engine.v`'s own *registered* `applied_slot`, landing at least one
  full cycle after `book_upd_valid`. By then the triggering message's
  register write has already committed, so `risk_engine.v` already sees
  genuinely post-update state. No change needed there.
- **`feature_extractor.v` has the identical latent defect** (same false
  "post-update state" claim, same bus, same `book_upd_valid` gating) but
  is not wired into anything yet (S6 blocked on S4) — **not fixed here**,
  no current consumer to break or verify against. Whoever writes S6's
  integration contract must wire `feature_extractor.v` to these same new
  `tob_engine.v` "next" ports, not the stale registered bus — flagged in
  D23, repeated here so it isn't missed twice.
- **`tob_top.v` itself is not touched by this contract.** Its currently
  delivered (uncommitted) `rtl/tob_top.v` wires `signal_engine.v`'s *old*
  port list. Once this patch lands, `tob_top.v`'s `u_sig` instantiation
  needs a small follow-up edit (§1.4) — separate work, after this is
  verified and committed.

### 1.4 Follow-up this patch creates (not this contract's job)

After this patch lands, `tob_top.v`'s `u_sig` instantiation
(`rtl/tob_top.v`, currently uncommitted) must be updated to connect
`tob_engine.v`'s new `next_*` outputs directly to `signal_engine.v`'s new
`next_*` inputs, and its now-unnecessary `bid_price`/`bid_qty`/`bid_valid`/
`ask_price`/`ask_qty`/`ask_valid`/`crossed` connections to `signal_engine.v`
removed (those buses are still needed elsewhere — `risk_engine.v` still
reads them — only the `signal_engine.v` connection goes away).
`tb_tob_top.v`'s T1 case should also be revisited: once the fix is
verified, two messages (bid, ask) should suffice to fire a signal, and the
third re-quote can be dropped, directly demonstrating the fix at the
integration level. **Neither edit is part of this contract** — it's
`tob_top.v`'s own follow-up, done after this lands.

## 2. What you're building

**Files:** `rtl/tob_engine.v` (patch), `rtl/signal_engine.v` (patch)
**Testbenches:** `tb/tb_tob_engine.v` (new cases), `tb/tb_signal_engine.v`
(rewritten to match the new port shape, same coverage), new
`tb/tb_signal_tob_chain.v` (§2.3)

### 2.1 `tob_engine.v` patch — additive, seven new output ports

```verilog
// new ports, added to the existing list -- nothing else on this module's
// interface changes
output wire [31:0] next_bid_price,
output wire [31:0] next_bid_qty,
output wire         next_bid_valid,
output wire [31:0] next_ask_price,
output wire [31:0] next_ask_qty,
output wire         next_ask_valid,
output wire         next_crossed
```

```verilog
// at the point nb_bp/nb_bq/.../addr_crossed_next are already computed --
// plain assigns, zero new logic:
assign next_bid_price = nb_bp;
assign next_bid_qty   = nb_bq;
assign next_bid_valid = nb_bv;
assign next_ask_price = nb_ap;
assign next_ask_qty   = nb_aq;
assign next_ask_valid = nb_av;
assign next_crossed   = addr_crossed_next;
```

These reflect the applied slot's state **as it will be after this cycle's
edge** — valid whenever `msg_applied` is high (same scope as
`book_upd_valid`; for a TRADE/HEARTBEAT cycle, where `nb_* == s_*` by
construction, they simply equal the current state, which is correct: no
update happened, so "next" and "current" are the same value). When
`msg_applied` is low, these are the same don't-care they already are
internally — no consumer should read them without gating on
`book_upd_valid` first, exactly as `signal_engine.v` already does for the
old bus.

### 2.2 `signal_engine.v` patch — new port shape, no latency change

**Remove** the flattened, `NUM_SYMBOLS`-wide input ports entirely:
`bid_price`, `bid_qty`, `bid_valid`, `ask_price`, `ask_qty`, `ask_valid`,
`crossed`. **Remove** the `NUM_SYMBOLS` parameter — nothing on this
module's interface indexes a per-symbol bus anymore, so it no longer needs
to know that width. `applied_slot` stays (still needed for
`sig_slot <= applied_slot`).

**Add** seven new scalar input ports, matching `tob_engine.v`'s new
outputs 1:1:

```verilog
input  wire [31:0] next_bid_price,
input  wire [31:0] next_bid_qty,
input  wire         next_bid_valid,
input  wire [31:0] next_ask_price,
input  wire [31:0] next_ask_qty,
input  wire         next_ask_valid,
input  wire         next_crossed
```

**Repoint the internal `s_*` aliases** to the new ports instead of
indexing the old bus — this is the entire behavioral change, everything
downstream of these seven lines (`ask_shifted`/`bid_shifted`/`buy_qty_ok`/
`sell_qty_ok`/`spread_ok`/`base_ok`/`buy_ok`/`sell_ok`/`conflict`/the
registered-output `always` block) is **untouched**, byte-for-byte:

```verilog
// old (delete):
wire [31:0] s_bp = bid_price [applied_slot*32 +: 32];
wire [31:0] s_bq = bid_qty   [applied_slot*32 +: 32];
wire        s_bv = bid_valid [applied_slot];
wire [31:0] s_ap = ask_price [applied_slot*32 +: 32];
wire [31:0] s_aq = ask_qty   [applied_slot*32 +: 32];
wire        s_av = ask_valid [applied_slot];
wire        s_cr = crossed   [applied_slot];

// new:
wire [31:0] s_bp = next_bid_price;
wire [31:0] s_bq = next_bid_qty;
wire        s_bv = next_bid_valid;
wire [31:0] s_ap = next_ask_price;
wire [31:0] s_aq = next_ask_qty;
wire        s_av = next_ask_valid;
wire        s_cr = next_crossed;
```

No change to D15's wide-precision imbalance-shift arithmetic, the
crossed-book underflow handling, `err_signal_conflict`'s timing, or the
registered order-intent logic — all of that operates on `s_bp`/`s_bq`/etc,
which now simply come from a different (correct) source.

### 2.3 New cross-module regression: `tb/tb_signal_tob_chain.v`

**The root cause of this whole bug was that no test ever chained the two
real modules together** (D23) — every existing testbench drives its DUT's
inputs directly, independent of what the *actual upstream module* would
produce. This new, permanent testbench closes that gap for good: it
instantiates the **real** `rtl/tob_engine.v` and `rtl/signal_engine.v`
together (no `tob_top.v`, no other module needed — this is deliberately
minimal, matching exactly the shape of the isolated reproduction D23 used
to confirm the bug), drives message-shaped stimulus into `tob_engine.v`'s
own inputs, and checks `signal_engine.v`'s `sig_valid`/`sig_side`/
`sig_price` against hand-computed expectations that match
`sim/golden_model.py`'s own post-update semantics — not against whatever
the (possibly still-buggy) RTL produces.

Cover, at minimum:

- **The exact D23 reproduction, now expected to pass:** bid QUOTE
  (1000/100), then ask QUOTE (1005/1) — confirm `sig_valid` fires on the
  **ask QUOTE's own cycle** (registered one cycle later), not on some
  subsequent unrelated message. This is the single most important case in
  this file — it is a direct, permanent regression against the exact bug
  D23 found.
- **A QUOTE that completes an already-tradeable book from the other
  side** (ask first, then bid) — same requirement, mirrored.
  Buy vs sell as appropriate (spread/imbalance sized for a sell instead).
- **A CLEAR that immediately follows, book still empty:** confirm no
  spurious signal.
- **Multiple symbols interleaved** (reusing `tob_engine.v`'s
  `NUM_SYMBOLS=4` slots): confirm a signal on slot 2 doesn't fire from
  slot 0's book state, and vice versa — this exercises `applied_slot`
  routing end to end through both real modules together.
- **TRADE/HEARTBEAT between two QUOTEs:** confirm they neither fire a
  signal themselves nor corrupt the eventual QUOTE-triggered one (per
  §2.1, their `next_*` values equal current state, a no-op for signal
  purposes).
- On any mismatch, `$display` what was expected vs. actual (which
  message, expected `sig_valid`/`sig_side`/`sig_price`, actual), then a
  final `$display("FAIL")` / `$display("PASS")` line.

## 3. Testbench requirements

### 3.1 `tb/tb_tob_engine.v` — new cases

Add cases confirming the seven new outputs are correct for the applied
slot on both message types that modify the book, and correctly equal
current state (no-op) for the two that don't:

- A `QUOTE` (bid side): `next_bid_price`/`next_bid_qty`/`next_bid_valid`
  equal what the *registered* state will read on the *next* cycle (i.e.
  cross-check `next_bid_price` sampled at the `book_upd_valid` cycle
  against `bid_price` sampled one cycle later — they must be equal).
  Mirror for the ask side.
- A `CLEAR`: `next_bid_valid`/`next_ask_valid` both read `0` on the
  `book_upd_valid` cycle itself (not one cycle later).
- A `TRADE`/`HEARTBEAT`: all seven `next_*` outputs equal the
  *pre-existing* current state (nothing changed) — this is the case that
  would catch an accidental unconditional pass-through of `msg_price`/
  `msg_quantity` regardless of `msg_type`.
- `next_crossed` specifically: construct a QUOTE that makes the applied
  slot crossed for the first time (previously not crossed), confirm
  `next_crossed` reads `1` on that same `book_upd_valid` cycle — this is
  the exact property `signal_engine.v` depends on for its own `~s_cr` term
  to correctly block a newly-crossed book's own triggering message.

### 3.2 `tb/tb_signal_engine.v` — rewrite to the new port shape, same coverage

The DUT's interface changed (§2.2), so the testbench's stimulus-driving
layer needs a corresponding rewrite: the existing `drive_bus` task and its
per-slot `mbp`/`mbq`/`map`/`maq`/`m_bv`/`m_av`/`m_cr` (4-wide) arrays are
no longer meaningful — the DUT has no per-symbol bus to index anymore, it
just reads whatever scalar `next_*` values are presented for whichever
slot is currently being applied. Replace them with direct assignment to
the new scalar ports inside the `cycle` task; `applied_slot` remains an
independent input (still needed for `sig_slot`), decoupled from the
book-state values themselves (a testbench is still free to present
different `next_*` values against different `applied_slot` numbers across
cycles, e.g. for the existing "I1-I3 independent slots" case's spirit — it
just no longer needs an actual multi-slot model to do so, since
`signal_engine.v` never sees any slot's state but the applied one).

**Every existing test case must be preserved, under the new port shape,
with equivalent coverage** — this is a mechanical adaptation of the
stimulus-driving layer, not a re-derivation of what to test:
`reset`, `A1-A3` (buy spread threshold), `B1-B3` (sell spread threshold,
mirror), `C1-C4` (imbalance strict-inequality boundary), `D1-D2` (crossed
book blocks both), `E1-E2` (either side invalid blocks both), `F` (D15
overflow-safety regression), `G` (FR-37 conflict, via force/release on the
DUT's internal `buy_ok`/`sell_ok` wires — unaffected by this patch, those
wires are downstream of `s_*` and unchanged), `H1-H2`
(`book_upd_valid = 0`), `I1-I3` (independent slots, per above).

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o tob_engine_tb.vvp rtl/tob_engine.v tb/tb_tob_engine.v` compiles with zero warnings; `vvp` prints `PASS`.
- [ ] `iverilog -g2001 -Wall -o signal_engine_tb.vvp rtl/signal_engine.v tb/tb_signal_engine.v` compiles with zero warnings; `vvp` prints `PASS`.
- [ ] `iverilog -g2001 -Wall -o chain_tb.vvp rtl/tob_engine.v rtl/signal_engine.v tb/tb_signal_tob_chain.v` compiles with zero warnings; `vvp` prints `PASS`.
- [ ] The exact D23 reproduction (bid QUOTE, then ask QUOTE, no third
      message) now fires `sig_valid` on the ask QUOTE's own cycle
      (registered one cycle later) — this is the headline fix, verify it
      directly, don't just trust the broader suite.
- [ ] `tob_engine.v`'s seven new outputs are purely additive — every
      existing `tb_tob_engine.v` case (pre-patch) still passes unmodified.
- [ ] `signal_engine.v`'s registered-output timing is unchanged — still
      exactly one cycle after `book_upd_valid`, confirmed by the
      preserved `H1-H2`/`A1-A3` cases' own timing assertions.
- [ ] `signal_engine.v` no longer has a `NUM_SYMBOLS` parameter or any
      per-symbol-indexed input.
- [ ] No inferred latches in either patched module; every `reg`/`wire`
      assigned on every path or has a clear default.

## 5. Explicitly out of scope

- `feature_extractor.v`'s identical latent defect (§1.3) — flagged, not
  fixed; no current consumer (S6 blocked). Whoever writes S6's
  integration must wire it to these same `next_*` ports.
- Any edit to `rtl/tob_top.v`, `tb/tb_tob_top.v`, or
  `docs/contracts/tob_top.md` — the follow-up wiring change this patch
  requires there (§1.4) is separate work, done after this patch is
  verified and committed.
- `risk_engine.v` — confirmed unaffected (§1.3), not touched.
- Any change to the master spec's decision rule itself (FR-35..40) — this
  is a bug fix bringing the RTL in line with the rule and the golden
  model as already specified, not a new rule.
