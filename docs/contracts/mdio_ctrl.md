# Contract: `rtl/common/mdio_ctrl.v` — KSZ9031RNX MDIO bring-up sequencer

> **Superseded 2026-09-01 — this contract targets the wrong PHY.** The board's
> actual chip is JLSemi JL2121(D), not the Micrel/Microchip KSZ9031RNX this
> document describes throughout. Full story in `docs/design_decisions.md` D9.
> The delivered `rtl/common/mdio_ctrl.v` has already been corrected: the three
> direct clause-22 writes below (§4 source 1) are unchanged — they're
> IEEE 802.3 standard registers, bit-identical on both chips — but **the
> entire §2.2/§3.2/§4 source 2 "MMD pad-skew" section no longer applies and
> was deleted from the module**, not re-targeted: the JL2121(D) tunes RGMII
> RX/TX delay via hardware strap pins, already fixed on this board, not via
> any MDIO register. The real module also adds a 10ms post-reset settle delay
> the JL2121(D) datasheet requires and this document never mentioned. Left
> below as a historical record of what was originally (incorrectly)
> specified — read D9 before reusing anything here, don't follow this
> document's §2.2/§3.2/§4-source-2 for new work.

Status: ready to hand off. Self-contained — no other context from this repo's
history should be needed to execute it. If something here is ambiguous, stop
and ask rather than guessing; do not invent register values.

## 1. Background (why this exists)

This is an FPGA project (Artix-7 XC7A35T on an ALINX AX7035B board) talking to
a Micrel/Microchip KSZ9031RNX Gigabit Ethernet PHY over RGMII. Before the PHY
will pass traffic reliably, a small one-time sequence of MDIO (clause-22
management) register writes should run after reset: advertise link
capabilities, and (recommended by the datasheet) set RGMII pad-skew values
explicitly rather than relying on undocumented defaults.

A previous version of this sequencer was borrowed from a third-party VHDL
project and has two problems this rewrite must fix:
1. It used PHY address `0`; this board's PHY is strapped to address **`1`**
   (schematic-confirmed).
2. It never touched the RGMII pad-skew registers at all.

This is a clean-room rewrite in Verilog-2001 (not a translation of the old
VHDL) — implement directly from the protocol description below and from the
datasheet section cited in §4.

## 2. What you're building

**File:** `rtl/common/mdio_ctrl.v`
**Testbench:** `tb/tb_mdio_ctrl.v` (self-checking, runs under Icarus Verilog:
`iverilog -g2001 -Wall -o mdio_ctrl_tb.vvp rtl/common/mdio_ctrl.v tb/tb_mdio_ctrl.v && vvp mdio_ctrl_tb.vvp`)

Verilog-2001 only — no SystemVerilog constructs (no `always_ff`, no
interfaces, no `logic`, no `assert` — this project's simulator for this file
is plain Icarus). One clock domain, no vendor primitives.

### 2.1 Module interface

```verilog
module mdio_ctrl #(
    parameter PHY_ADDR   = 5'b00001,  // KSZ9031RNX strapped address on this board
    parameter CLK_HZ     = 125_000_000,
    parameter MDC_HZ     = 2_500_000  // must not exceed IEEE 802.3 clause 22 max of 2.5 MHz
) (
    input  wire clk,        // free-running system clock (CLK_HZ)
    input  wire rst_n,      // active-low, synchronous is fine
    input  wire start,      // one-shot pulse: begin the sequence (ignored if already running)
    output reg  busy,        // high from `start` until the whole sequence completes
    output reg  done,        // one-cycle pulse when the whole sequence completes successfully
    output wire mdc,         // MDIO clock output to the PHY
    inout  wire mdio         // MDIO data, bidirectional (open-drain style: drive or release)
);
```

`mdio` is bidirectional: drive it during the frame's write-data phase (or the
turnaround bit on a read, if you implement reads — see §3.3), and set it to
high-impedance (`1'bz`) otherwise so the PHY (or a pull-up) can drive it back.

### 2.2 What the module does, end to end

On `start`, run this fixed sequence once, then pulse `done` and drop `busy`.
No retries, no link-status polling, no runtime reconfiguration — this is a
fire-once bring-up sequencer, not a general MDIO master. If a later stage of
the project needs ad hoc MDIO reads/writes, that is separate future work, not
part of this contract.

1. Three **direct clause-22 register writes** (per §3.1) to `PHY_ADDR`:
   advertise capabilities, master/slave config, and a control-register
   soft-reset with speed/duplex forced. Exact register numbers and values are
   in §4 — cross-check them against the reference file named there, but do
   not copy that file's code structure or comments; you're implementing the
   IEEE 802.3 clause 22 protocol and reproducing well-documented protocol
   constants, not translating someone else's RTL.
2. **Four indirect MMD (clause 45-over-22) writes** to MMD device address `2`
   at register addresses `4`, `5`, `6`, `8` — the KSZ9031RNX's RGMII pad-skew
   registers. Use the register layout and the datasheet's own documented
   default/recommended values (§4.2) — do not invent skew values. Writing the
   documented defaults back explicitly (rather than relying on the PHY's own
   power-up defaults) is the point: it makes the configuration visible and
   reproducible in this file instead of implicit in silicon.
3. Pulse `done` for one cycle, drop `busy`.

## 3. Protocol specification

### 3.1 Clause-22 MDIO frame (direct register write)

A write frame is transmitted on `mdio`, MSB first, synchronized to `mdc`
(IEEE 802.3 clause 22, §22.2.4):

| Field | Bits | Value |
| :-- | :-- | :-- |
| Preamble | 32 | all 1s |
| Start (ST) | 2 | `01` |
| Opcode (OP) | 2 | `01` = write |
| PHY address (PHYAD) | 5 | `PHY_ADDR` |
| Register address (REGAD) | 5 | the target register |
| Turnaround (TA) | 2 | `10` (driven by us on a write) |
| Data | 16 | the value to write, MSB first |

`mdc` toggles at ≤ `MDC_HZ`; derive it from `clk`/`CLK_HZ` with a simple
free-running divider (round down — never exceed 2.5 MHz). Data on `mdio` is
sampled by the PHY on the rising edge of `mdc`; change `mdio` on `mdc`'s
falling edge (standard practice — gives setup/hold margin without needing
IDELAY or PLL tricks).

### 3.2 Indirect MMD access (clause 45-over-22, "register 13/14" mechanism)

The KSZ9031RNX exposes its MMD (MDIO Manageable Device) registers — including
the pad-skew registers — through two ordinary clause-22 registers on the same
PHY address:

- Register `13` (`MMD Access Control`, `0x0D`)
- Register `14` (`MMD Access Address/Data`, `0x0E`)

To write MMD device `devad`, register `regad`, value `data`, issue four
ordinary clause-22 writes in this order (standard clause-45-over-22 indirect
sequence — this is the mechanism `miim_registers.vhd` in the reference tree
already names but never drives; you are completing it, not inventing it):

1. Write reg 13 = `{2'b00, 11'b0, devad[4:0]}` (function = address, `00`)
2. Write reg 14 = `regad` (the target MMD register address, full 16 bits)
3. Write reg 13 = `{2'b01, 11'b0, devad[4:0]}` (function = data, no post-increment, `01`)
4. Write reg 14 = `data` (the value to write)

(If your datasheet reading in §4 disagrees with this bit layout for reg 13,
follow the datasheet — it is the authority, this description is a starting
point.)

### 3.3 Reads

Not required for this contract. `busy`/`done` and the write-only sequence
above are the full scope. Leave `mdio` released (`1'bz`) whenever you are not
actively driving a bit.

## 4. Where to get the exact register values

**Do not guess these.** Two sources, both already in this repo:

1. **Direct-write register values (§2.2 step 1):** cross-check against
   `docs/refs/AX7035/SRC/21_ethernet_test/ethernet_test/rgmii_ethernet/eth_test.srcs/sources_1/new/miim/miim_control.vhd`
   and `miim_registers.vhd` in the same directory — these already encode the
   correct standard values for "advertise 10/100 full-duplex" (register 4),
   "advertise 1000BASE-T full-duplex" (register 9), and the control-register
   soft-reset with speed=1000/duplex=full/autoneg-enable (register 0). Read
   the values, not the VHDL structure — write fresh Verilog.
2. **MMD pad-skew register values (§2.2 step 2):** read
   `docs/refs/AX7035/DATASHEET/KSZ9031/KSZ9031RNX.pdf`, the section titled
   "RGMII Pad Skew Registers" (around pp. 23–26 — confirm the exact page in
   your copy, PDF page numbers can drift). It documents MMD device 2,
   registers `4`/`5`/`6`/`8` with per-line skew fields and their default/
   recommended bit patterns. Write those documented values back explicitly.
   If the datasheet gives a range or several recommended options, pick the
   documented *default* — do not tune by guesswork; tuning happens later on
   real hardware (S11) with a scope, not here.

If either source is missing, contradictory, or you can't access the PDF,
**stop and report back** rather than substituting an assumed value — a wrong
protocol constant here fails silently (the PHY just doesn't come up right, no
error message).

## 5. Testbench requirements (`tb/tb_mdio_ctrl.v`)

Self-checking, Icarus-runnable, no manual waveform inspection needed to pass:

- Instantiate `mdio_ctrl` with a fast test `MDC_HZ` if you want a shorter sim
  (parameter override), otherwise real timing is fine too.
- Model a minimal clause-22 MDIO slave in the testbench: watch `mdc`/`mdio`,
  decode each 32-bit-preamble + ST/OP/PHYAD/REGAD/TA/DATA frame, and check:
  - Every frame's PHYAD equals `5'b00001` (catches the exact bug this
    contract exists to fix).
  - The three direct-write register numbers and values match §4 source 1.
  - The four-write indirect sequences target MMD device 2, registers 4/5/6/8,
    with the values from §4 source 2, in the order reg13→reg14→reg13→reg14
    per skew register.
  - `mdc` never exceeds `MDC_HZ` (measure the period).
  - `done` pulses exactly once, after all 7 writes (3 direct + 4 indirect),
    and `busy` is high for the entire sequence and low before/after.
- On any mismatch, `$display` the frame number, expected vs. actual, and
  `$finish` with a nonzero indication (e.g. a final `$display("FAIL")` /
  `$display("PASS")` line the caller can grep for) — no test framework
  dependency, this project's convention is plain self-checking Verilog.

## 6. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o mdio_ctrl_tb.vvp rtl/common/mdio_ctrl.v tb/tb_mdio_ctrl.v` compiles with zero warnings.
- [ ] `vvp mdio_ctrl_tb.vvp` prints `PASS` and exits.
- [ ] `mdio_ctrl.v` contains no SystemVerilog constructs (Verilog-2001 only).
- [ ] Every MDIO frame in simulation uses `PHYAD = 5'b00001`.
- [ ] All 4 MMD pad-skew registers (2.4, 2.5, 2.6, 2.8) are written, with
      values traceable to the datasheet section cited in §4, not invented.
- [ ] `mdc` frequency in simulation is ≤ 2.5 MHz (or ≤ your overridden
      `MDC_HZ` parameter).
- [ ] No `x`/`z` glitches on `mdio` while it's being driven (i.e., you're not
      accidentally driving from an uninitialized register).

## 7. Explicitly out of scope

- Link-up/speed detection or status output — this module only sequences
  writes, nothing reads status back.
- Runtime/CSR-driven reconfiguration — this is a fixed, compile-time sequence
  that runs once after reset.
- Anything about the Ethernet MAC datapath itself (`mac_top.v` and friends) —
  unrelated to this module.
