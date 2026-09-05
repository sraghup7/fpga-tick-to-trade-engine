# Contract: `rtl/frame_classifier.v`

Status: ready to hand off. Self-contained. **Depends on**
`docs/contracts/eth_mac_if_rx_len.md` having already landed (`rtl/eth_mac_if.v`
must already expose `frame_start`/`rx_len`) — confirm those two ports exist
on `eth_mac_if.v` before starting. If they don't, stop and say so rather than
adding them yourself here (that's a separate, already-specified contract).

## 1. Background (why this exists)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain) that receives a synthetic market-data feed over Ethernet.
Messages are fixed-width, 16 bytes, packed 1–88 per frame with no padding.
`frame_classifier.v` sits between the existing `rtl/eth_mac_if.v` (byte
stream out of the MAC) and a new `md_parser.v` (byte-serial message
decoder, being built separately against this module's output — see
`docs/contracts/md_parser.md`). Its only job is to reject a frame whose
payload length is not a valid whole number of messages, **before**
forwarding any of that frame's bytes — a bad frame must be discarded whole,
not partially parsed.

Two facts from the wider system this module does NOT need to worry about
(so you don't go looking for logic that isn't your job):

- **EtherType / IPv4 / UDP-port classification is already done upstream.**
  The vendored MAC (`rtl/vendor/alinx_mac/`) only ever presents a frame to
  `eth_mac_if.v` after it has already verified EtherType, IPv4 header
  checksum, and UDP framing — this module does not re-parse any of that
  (`docs/design_decisions.md` D1). It only sees payload bytes and a
  declared length.
- **`LINK_MODE=0` (raw Ethernet) is out of scope** — deferred project-wide
  (`docs/design_decisions.md` D3). Only the UDP path described above is
  implemented.

## 2. What you're building

**File:** `rtl/frame_classifier.v`
**Testbench:** `tb/tb_frame_classifier.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module frame_classifier #(
    parameter integer MAX_FRAME_BYTES = 1408   // 88 messages * 16 bytes
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low; treat like the rest of this
                                 // datapath's modules (see rtl/eth_mac_if.v
                                 // or rtl/tob_top.v for the reset style
                                 // already used elsewhere in this repo)

    // from eth_mac_if.v
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        frame_start, // pulses once per frame, incl. zero-length
    input  wire [15:0] rx_len,      // this frame's declared length; stable
                                     // for the frame's whole duration

    // to md_parser.v
    output wire [7:0]  out_data,
    output wire        out_valid,

    // status: one-cycle pulse per discarded frame (incl. zero-length)
    output wire        err_frame_len
);
```

Do not add any other ports (no `rx_last` passthrough, no "frame valid"
output separate from gating `out_valid` itself — nothing downstream needs
them; see §5 Out of scope).

### 2.2 Accept/reject rule (evaluate from `rx_len`, not by counting bytes)

A frame is **valid** iff all three hold:

1. `rx_len != 0`
2. `rx_len` is a whole multiple of 16
3. `rx_len <= MAX_FRAME_BYTES` (1408 by default — i.e. at most 88 messages)

This is available the same cycle `frame_start` pulses (`rx_len` is valid and
stable from that cycle through the whole frame — guaranteed by
`eth_mac_if.v`, not something this module needs to verify). Because the
answer is known before the first byte, no FSM and no buffering of any
kind is needed or wanted here — see §2.4.

### 2.3 Output behavior

- **Valid frame:** every byte of `rx_valid`/`rx_data` for that frame is
  forwarded unchanged and immediately (same cycle) as `out_valid`/`out_data`.
  No added latency.
- **Invalid frame:** **zero** bytes are ever forwarded for that frame —
  `out_valid` stays low for its entire duration, even though `rx_valid` may
  pulse for however many bytes the vendor MAC actually delivered (a frame
  can have a "wrong" length and still have real bytes behind it — e.g. 17
  declared bytes actually streaming 17 bytes on `rx_valid`; none of them
  should reach `out_data`/`out_valid`).
- **`err_frame_len`:** pulse for exactly one clock cycle per rejected frame,
  timed off `frame_start` (so it fires even for a frame with zero
  subsequent bytes — see §2.4's last paragraph). It must not pulse for a
  valid frame.
- The very next frame after a rejected one must be classified and forwarded
  completely normally — no stuck state, no need for an explicit "return to
  idle" step, since there is no FSM to get stuck (§2.4).

### 2.4 Why this can be pure combinational gating (no FSM, no buffer)

This is the key design constraint of this contract — please follow it
rather than building a state machine or a per-frame buffer, both of which
would be unnecessary here and would violate this project's fast-path rules
(no FIFO whose fullness depends on message content; every fast-path
structure has fixed, elaboration-time depth):

Because `rx_len` is stable and valid for the *entire* frame (not just at its
start), the accept/reject decision can be recomputed live, every cycle,
directly from `rx_len`, and used to gate `out_valid` combinationally:
conceptually `out_valid = rx_valid AND <the three checks in §2.2>`. There is
no need to latch the decision at frame start and hold it — recomputing it
every cycle from a value that never changes mid-frame gives the identical
result with less logic.

`err_frame_len`, on the other hand, must fire exactly **once** per bad
frame, not once per bad byte (a 17-byte bad frame streams 17 bytes of
`rx_valid`, but should only produce **one** `err_frame_len` pulse, not
seventeen). Tie it to `frame_start` specifically (the one-cycle-per-frame
event), not to `rx_valid`. This is also the only way a **zero-length**
frame's rejection is observable at all: it has no bytes, so nothing
byte-gated would ever fire for it, but `frame_start` still pulses once for
it regardless of length (that's the whole reason `frame_start` exists as a
separate signal from `rx_valid` — see `docs/contracts/eth_mac_if_rx_len.md` §2.3
if you want the full reasoning).

## 3. Testbench requirements (`tb/tb_frame_classifier.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o frame_classifier_tb.vvp rtl/frame_classifier.v tb/tb_frame_classifier.v && vvp frame_classifier_tb.vvp`),
no manual waveform inspection needed. Drive `rx_data`/`rx_valid`/
`frame_start`/`rx_len` directly (this module's whole input contract — no
need to instantiate `eth_mac_if.v` itself). Cover, at minimum:

- **One 16-byte frame** (a single message): forwarded byte-for-byte
  unchanged, `err_frame_len` never pulses.
- **One 1408-byte frame** (88 packed messages): forwarded byte-for-byte
  unchanged, in order, `err_frame_len` never pulses.
- **Bad length 17**: streams 17 bytes on `rx_valid`, but zero bytes ever
  reach `out_data`/`out_valid`; `err_frame_len` pulses **exactly once**.
- **Bad length 15**: same shape, streams 15 bytes, zero forwarded, one
  `err_frame_len` pulse.
- **Bad length 0**: `frame_start` pulses, `rx_valid` never asserts at all
  (nothing to stream); `err_frame_len` still pulses **exactly once**. This
  is the case most likely to be silently missed by an implementation that
  derives its error pulse from `rx_valid`'s edge instead of `frame_start` —
  make sure your testbench actually exercises it, don't skip it because "no
  bytes happen anyway."
- **Bad length 1424** (89×16 — a *clean* multiple of 16, but one message
  over the 88-message limit): rejected the same way as the other bad-length
  cases. This exercises the upper-bound check specifically, distinct from
  the "not a multiple of 16" checks above.
- **Recovery:** immediately after any rejected frame, send one more good
  16-byte frame and confirm it is forwarded correctly with no leftover
  `err_frame_len` pulse and no corrupted/missing bytes — proves there's no
  stuck state between frames.
- On any mismatch, `$display` what was expected vs. what happened (byte
  index, or pulse count), then a final `$display("FAIL")` /
  `$display("PASS")` line the caller can grep for — this project's
  no-framework, plain self-checking-Verilog convention (see any existing
  `tb/tb_*.v` file for the exact style, e.g. `tb/tb_counter_sat.v`).

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o frame_classifier_tb.vvp rtl/frame_classifier.v tb/tb_frame_classifier.v` compiles with zero warnings.
- [ ] `vvp frame_classifier_tb.vvp` prints `PASS`.
- [ ] `rtl/frame_classifier.v` is Verilog-2001 only (no SystemVerilog).
- [ ] No FSM, no per-frame buffer/FIFO of any kind — the accept/reject gate
      is purely combinational off `rx_len`/`rx_valid`, per §2.4. If your
      implementation needs to buffer bytes to make a decision, you have
      missed why `rx_len` is exposed the way it is — re-read §2.4 before
      submitting.
- [ ] Zero-length frame (`rx_len == 0`) correctly produces exactly one
      `err_frame_len` pulse with zero bytes forwarded — tested explicitly,
      not incidentally.
- [ ] The 89-message (1424-byte) upper-bound case is tested and rejected.
- [ ] No inferred latches (every `reg`, if you use any at all, is assigned
      on every path through its `always` block, or has a clear default).

## 5. Explicitly out of scope

- Re-parsing EtherType/IPv4/UDP-port — already done upstream by the vendored
  MAC for the only link mode implemented (`docs/design_decisions.md` D1).
- `LINK_MODE=0` (raw Ethernet) support.
- Anything about `md_parser.v` itself (message-field decode, `msg_type`/
  `flags` validation) — separate contract, `docs/contracts/md_parser.md`.
- Forwarding `rx_last` or any other frame-boundary marker downstream —
  `md_parser.v` does not need one (it reconstructs message boundaries from a
  free-running byte counter, relying on this module's guarantee that it
  only ever forwards whole multiples of 16 bytes). Do not add a `last`
  output "for completeness."
- Any counter/register that persists `err_frame_len`'s count — that's a
  later stage's job (CSR/counters block); this module only emits the raw
  one-cycle pulse.
