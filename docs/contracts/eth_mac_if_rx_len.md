# Contract: `rtl/eth_mac_if.v` — expose `frame_start` / `rx_len`

Status: ready to hand off. This is a small, surgical patch to an **existing,
already-verified** module — not a new module. Read `docs/design_decisions.md`
D10 first (short) to understand what `eth_mac_if.v` already does; do not
change anything about its existing behavior. Self-contained otherwise. If
something here is ambiguous, stop and ask rather than guessing.

## 1. Background (why this exists)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain). `rtl/eth_mac_if.v` already adapts a vendored Ethernet MAC's
whole-frame-buffered RX RAM into a plain byte stream: `rx_data[7:0]` /
`rx_valid` / `rx_last`, presented to whatever's downstream (a new module,
`frame_classifier.v`, being built against this contract's output in a
separate task).

`frame_classifier.v` needs to reject a market-data frame whose declared
byte length is not a whole, in-range multiple of 16 (16 bytes per message,
1–88 messages per frame) — and it needs to do this **before forwarding a
single byte** of a bad frame, not partway through. That means it needs to
know the frame's length before (or at latest, in the same cycle as) the
frame's first byte arrives. `eth_mac_if.v` already computes exactly this
internally for its own RX walk, but doesn't expose it. This contract adds
two output ports that are plain aliases of signals the module already has —
no new logic, no behavior change to anything that exists today.

## 2. What you're building

**File to modify:** `rtl/eth_mac_if.v` (existing file — read it in full
first; do not rewrite it, only add to it)
**Testbenches to re-run (not modify):** `tb/tb_eth_mac_if_rx.v`,
`tb/tb_eth_mac_if_tx.v` (existing, already passing — see §4)

### 2.1 Two new output ports

Add these to the module's port list, alongside the existing `rx_data` /
`rx_valid` / `rx_last` outputs:

```verilog
output wire        frame_start, // one-cycle pulse: a new frame's rx_len is now
                                 // valid, INCLUDING a zero-length frame (see 2.3)
output wire [15:0] rx_len,      // this frame's declared byte length; stable
                                 // from frame_start until the *next* frame_start
```

### 2.2 What drives them

The module already has an internal wire, conventionally named something like
`valid_rise` (it's the rising edge of the vendor RAM boundary's
`udp_rec_data_valid` signal — the exact name may differ slightly in your
copy of the file, use whatever the module already calls it), and it already
reads the vendor boundary's declared-length input (`udp_rec_data_length`).
Both new ports are **plain continuous assigns of these two already-existing
signals** — do not add any registers, any delay, or any additional logic:

```verilog
assign frame_start = <the module's existing valid-rising-edge wire>;
assign rx_len       = <the module's existing declared-length input, e.g. udp_rec_data_length>;
```

If the module's existing internal signal names differ from this
description, use the module's actual names — the point is these are direct
taps on signals that already exist, not new computation.

### 2.3 Why `frame_start` can't just be `rx_valid`'s rising edge

This is the one non-obvious requirement in this contract, so read it before
implementing: a **zero-length** frame (`udp_rec_data_length == 0`) is a real
test case downstream (`frame_classifier.v`'s FR-5 coverage includes payload
length 0). Trace through the module's existing RX-walk logic: when the
declared length is 0, the walk logic never has any address to present, so it
never asserts `rx_valid` at all for that frame — there are no bytes to
signal. If `frame_start` were derived from `rx_valid`'s rising edge instead
of the vendor boundary's own valid-rising-edge signal, a zero-length frame
would be **completely invisible** downstream: no pulse, no way to detect or
count it. `frame_start` must fire on every frame the vendor boundary
presents, independent of whether the walk logic goes on to produce any
bytes.

### 2.4 Stability guarantee `rx_len` relies on

`rx_len` (== the vendor boundary's declared length) is guaranteed by the
vendor RTL to remain stable for at least as long as the *current* frame's
entire RX walk takes, and typically well beyond that (the vendor holds its
own valid signal high "until the next frame's reception reaches its own
tail end" — see the module's own existing header comment, and
`docs/design_decisions.md` D1). This means downstream logic (`frame_classifier.v`)
is safe to read `rx_len` combinationally, live, throughout a frame's byte
stream, with no need to latch it — that's `frame_classifier.v`'s problem to
rely on, not something you need to add buffering or latching for here. Just
expose the two wires as specified; do not add any latching logic to this
module on their behalf.

## 3. What must NOT change

- No change to the existing `rx_data` / `rx_valid` / `rx_last` behavior,
  timing, or the RX-walk state machine.
- No change to the TX side at all.
- No change to any existing port's name, width, or direction.
- No new parameters.

## 4. Verify no regression (do not skip this)

Both existing testbenches use named-port connection (`.rx_data(rx_data)`
style) and do not list every port of the DUT, so adding two new *output*
ports requires no changes on their end — an unconnected output in a named
instantiation is legal Verilog and produces no warning. Confirm this rather
than assuming it:

```bash
iverilog -g2001 -Wall -o /tmp/eth_mac_if_rx_tb.vvp rtl/eth_mac_if.v tb/tb_eth_mac_if_rx.v
vvp /tmp/eth_mac_if_rx_tb.vvp
```

Expected: compiles with **zero warnings**, prints `PASS`. Do the same for
`tb/tb_eth_mac_if_tx.v` — check that file's own header comment for its exact
compile invocation (it needs additional vendored sources and
`tb/sim_models/xilinx_ip_sim_models.v`; mirror what's already there rather
than guessing).

If either testbench now fails or produces a new warning, you have changed
something you shouldn't have — do not modify the testbench to make it pass;
find and fix the regression in `eth_mac_if.v`.

## 5. Acceptance criteria

- [ ] `rtl/eth_mac_if.v` still contains no SystemVerilog constructs
      (Verilog-2001 only).
- [ ] Exactly two new output ports added: `frame_start` (1 bit),
      `rx_len` (16 bits). No other port changes.
- [ ] Both new ports are plain continuous assigns of pre-existing internal
      signals — no new registers, no new state, no new always blocks.
- [ ] `frame_start` pulses for every frame the vendor RX boundary presents,
      including a zero-length one (verify this specifically — see §2.3).
- [ ] `tb/tb_eth_mac_if_rx.v` and `tb/tb_eth_mac_if_tx.v` still compile with
      zero warnings and still print `PASS`, unmodified.
- [ ] No inferred latches, no combinational feedback.

## 6. Explicitly out of scope

- Building `frame_classifier.v` itself — separate contract
  (`docs/contracts/frame_classifier.md`), which consumes these two new
  ports.
- Anything about `LINK_MODE=0` (raw Ethernet) — deferred project-wide, see
  `docs/design_decisions.md` D3.
- Any change to the vendored MAC (`rtl/vendor/alinx_mac/`) — this contract
  touches only `rtl/eth_mac_if.v`, the hand-written adapter.
