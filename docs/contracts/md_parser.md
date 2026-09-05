# Contract: `rtl/md_parser.v`

Status: ready to hand off. Self-contained. **Can be implemented in parallel
with `docs/contracts/frame_classifier.md`** — this module's actual input
contract (`in_data`/`in_valid`) doesn't require `frame_classifier.v` to
exist yet, only to match its documented output shape (see §1). Do not guess
at wire-format field values; they're fully specified below.

## 1. Background (why this exists, and the guarantee you can rely on)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain) parsing a synthetic market-data feed. Messages are fixed
width, 16 bytes, big-endian (network byte order), packed back-to-back with
no padding, 1–88 per frame.

`md_parser.v` sits directly downstream of `frame_classifier.v`
(`docs/contracts/frame_classifier.md`), which guarantees the following
about the byte stream it forwards: **every run of bytes it forwards is a
whole multiple of 16 bytes** — a frame with a bad length is rejected
entirely upstream, before this module ever sees any of its bytes. This is
the one fact this whole contract leans on: `md_parser.v` needs **no
frame-boundary awareness of its own**. A free-running, wrap-at-16 byte
counter, reset only at power-on, will always land byte 0 of a new message
exactly where a new message actually starts, for as long as that upstream
guarantee holds. Do not add any logic here that tries to detect frame
boundaries, resync on some marker, or otherwise second-guess this — it adds
complexity for a case (misalignment) that the upstream contract already
rules out.

## 2. What you're building

**File:** `rtl/md_parser.v`
**Testbench:** `tb/tb_md_parser.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module md_parser (
    input  wire        clk,
    input  wire        rst_n,   // active-low; match the reset style already
                                 // used elsewhere in this repo (see
                                 // rtl/eth_mac_if.v or rtl/tob_top.v)

    // from frame_classifier.v (or its testbench, standing in for it)
    input  wire [7:0]  in_data,
    input  wire        in_valid,

    // one decoded message per msg_valid pulse
    output wire        msg_valid,
    output wire [7:0]  msg_type,
    output wire [7:0]  msg_symbol_id,
    output wire [7:0]  msg_side,
    output wire [7:0]  msg_flags,
    output wire [31:0] msg_price,
    output wire [31:0] msg_quantity,
    output wire [31:0] msg_seq_num,

    // status: one-cycle pulse, coincides with a dropped (non-msg_valid) message
    output wire        err_msg_type,
    output wire        err_flags
);
```

(Whether the field outputs are internally `reg` or `wire` is your
implementation choice — the interface above is the port *direction and
width* contract, not a statement about internal storage.)

### 2.2 Wire format — exact byte layout (big-endian, MSB of each field first)

| Byte offset | Size | Field | Notes |
| :-- | :-- | :-- | :-- |
| 0 | 1 | `msg_type` | see §2.3 for valid values |
| 1 | 1 | `msg_symbol_id` | any value 0–255, no validation needed here |
| 2 | 1 | `msg_side` | any value 0–255, no validation needed here |
| 3 | 1 | `msg_flags` | see §2.4 for validation |
| 4–7 | 4 | `msg_price` | unsigned, big-endian (`in_data` at offset 4 is bits [31:24], offset 7 is bits [7:0]) |
| 8–11 | 4 | `msg_quantity` | unsigned, big-endian, same byte ordering as price |
| 12–15 | 4 | `msg_seq_num` | unsigned, big-endian, same byte ordering as price |

One byte of `in_data` arrives per cycle of `in_valid`. Byte 0 of message N
immediately follows byte 15 of message N−1 — no gap, no separator (this is
exactly what §1's "whole multiples of 16" guarantee buys you: a
free-running mod-16 counter over cycles where `in_valid` is high stays
aligned to message boundaries indefinitely).

### 2.3 `msg_type` validation (FR-8)

Valid values, exactly these four:

| Value | Meaning |
| :-- | :-- |
| `0x01` | quote update |
| `0x02` | trade print |
| `0x03` | book clear |
| `0xFF` | heartbeat |

Any other value is **undefined** → the message is dropped (no `msg_valid`
pulse for it) and `err_msg_type` pulses instead.

### 2.4 `flags` validation (FR-9)

`flags` bit 0 = end-of-burst, bit 1 = snapshot, **bits 7:2 are reserved and
must be 0**. If any of bits 7:2 are set, the message is dropped (no
`msg_valid` pulse) and `err_flags` pulses instead.

### 2.5 Validation order matters — check type before flags

This is not an arbitrary implementation detail — it must match this
project's Python reference model (`sim/golden_model.py`'s
`process_message`) bit-for-bit, including *which* error fires when a
message is broken in more than one way at once (though in practice
`msg_type` and `flags` are independent fields, so a message is never
invalid in both ways simultaneously — check type first anyway, for
consistency with the reference model's stated order):

1. Is `msg_type` one of the four valid values? If not: `err_msg_type`
   pulses, done, no `msg_valid`.
2. Otherwise, are `flags` bits 7:2 all zero? If not: `err_flags` pulses,
   done, no `msg_valid`.
3. Otherwise: `msg_valid` pulses, with all seven fields presented.

### 2.6 Timing: when do the pulses/outputs happen relative to the input bytes?

The 16th byte of a message (byte offset 15, `msg_seq_num`'s low byte)
arrives on some cycle N (i.e. `in_valid` is high on cycle N and this is the
16th byte since the last message boundary). The corresponding `msg_valid` /
`err_msg_type` / `err_flags` pulse, and all seven field outputs reflecting
that complete message, must appear **starting the cycle after** cycle N —
i.e. one cycle after the last byte was consumed, not the same cycle
(whatever register(s) hold the assembled fields need one clock edge to
actually latch that last byte before anything downstream can correctly read
them). Do not try to make it same-cycle/combinational off the incoming byte
— that would require reading a field register in the same edge it's being
written, which is not meaningfully different from reading a stale value.

## 3. Testbench requirements (`tb/tb_md_parser.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o md_parser_tb.vvp rtl/md_parser.v tb/tb_md_parser.v && vvp md_parser_tb.vvp`),
no manual waveform inspection needed. Drive `in_data`/`in_valid` directly as
a continuous, already-16-byte-aligned stream (this module's whole input
contract — no need to instantiate `frame_classifier.v`). Cover, at minimum:

- **One message** (pick any valid `msg_type`, arbitrary field values):
  decodes to exactly the fields it was built from, `msg_valid` pulses once,
  no `err_*` pulses.
- **88 back-to-back messages** in one continuous stream, cycling through
  all four valid `msg_type` values across them: all 88 decode correctly, in
  order, with field values matching what was sent for each one; zero
  `err_*` pulses anywhere in the run.
- **An undefined `msg_type`** (e.g. `0x07`) embedded between two otherwise
  normal messages: the bad one produces `err_msg_type` (exactly once, not
  `msg_valid`), and — this is the part worth checking explicitly, not just
  assuming — the normal messages immediately before and after it still
  decode with their own correct field values, proving the byte counter
  never lost alignment because of the dropped message.
- **A reserved `flags` bit set** (e.g. bit 2, i.e. `flags = 0x04`) embedded
  the same way: produces `err_flags` (exactly once, not `msg_valid`),
  surrounding messages still decode correctly.
- On any mismatch, `$display` what was expected vs. what happened (which
  test, which field, expected vs. actual value), then a final
  `$display("FAIL")` / `$display("PASS")` line the caller can grep for —
  this project's plain self-checking-Verilog convention (see any existing
  `tb/tb_*.v` for the exact style).

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o md_parser_tb.vvp rtl/md_parser.v tb/tb_md_parser.v` compiles with zero warnings.
- [ ] `vvp md_parser_tb.vvp` prints `PASS`.
- [ ] `rtl/md_parser.v` is Verilog-2001 only (no SystemVerilog).
- [ ] No frame-boundary-detection logic of any kind (no searching for a
      marker, no resync state machine) — a plain free-running mod-16
      counter is sufficient and is what this contract expects; see §1.
- [ ] `msg_type` checked before `flags` (§2.5), not the other way around and
      not in parallel with no defined priority.
- [ ] The undefined-`msg_type` and reserved-`flags` test cases both verify
      that the messages immediately surrounding the dropped one still
      decode correctly (not just that the bad one was dropped).
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Any awareness of frame boundaries — see §1; that's `frame_classifier.v`'s
  job entirely, already done before this module sees a byte.
- Symbol filtering, sequence-gap detection, book state, or anything about
  what happens to a *valid* decoded message after it leaves this module —
  those are later modules (`symbol_filter.v`, `seq_monitor.v`,
  `tob_engine.v`), not built yet, not this contract's concern.
- Counters that persist `err_msg_type`/`err_flags` counts — this module
  only emits the raw one-cycle pulses; a later CSR/counters block owns
  accumulating them.
- Validating `msg_symbol_id`, `msg_side`, `msg_price`, `msg_quantity`, or
  `msg_seq_num` in any way — none of those fields have a "bad value" at
  this layer; they're just decoded and passed through.
