# AX7035B pin/bank facts extracted from ALINX documentation

**Update: the real PDF is now in hand**, at `Manuals/AX7035B_UG.pdf` (Rev
1.0, 33 pages, Chinese). Everything below that came from the ManualsLib
text-extract-plus-third-party-mirror reconstruction has been re-checked
against it. All fifteen RGMII/MDIO pins and the UART/reset-key/KEY1-4 pins
matched exactly — that reconstruction held up. **One thing in it did not
hold up: the chip identity.** See "The KSZ9031RNX line was always wrong"
below before trusting anything in this file that still says KSZ9031RNX.

Originally compiled by reading the ALINX AX7035 User Manual page-by-page via
ManualsLib (https://www.manualslib.com/manual/2994570/Alinx-Ax7035.html) and
the official product page
(https://en.alinx.com/Product/FPGA-Development-Boards/Artix-7/AX7035B.html).

**Not the original PDF, at the time.** Both ManualsLib's download and
ALINX's own site gate the full PDF behind account sign-up / email
verification, which wasn't something to submit on your behalf without asking
first. This was a compiled set of facts with page citations, sufficient for
what Stage 2 needed (clock + LED pins) and a head start for later stages
(full RGMII pinout). That gap is closed now that the real PDF has arrived.

## The KSZ9031RNX line was always wrong — and the manual itself explains why

`spec/PROJECT_SPEC.md` A.2 v0.2 stated the ALINX manual "states the actual
chip is a Micrel/Microchip KSZ9031RNX." B.5 bring-up's MDIO PHY-ID read
(`0x937c4032`) proved that false — the chip is a JLSemi JL2121(D) — and the
real manual explains exactly how the KSZ9031RNX claim got into this project
in the first place. Page 13 of `AX7035B_UG.pdf` reads (translated):

> "The AX7035B development board provides network communication services
> through a Jinglue Semiconductor JL2121-N040I Ethernet PHY chip... The
> JL2121-N040I chip supports 10/100/1000 Mbps... **KSZ9031RNX supports
> MDI/MDX auto-negotiation, all-speed auto-negotiation, Master/Slave
> auto-negotiation, and supports the MDIO bus for PHY register management.**"

That middle sentence is a leftover from ALINX reusing boilerplate text from
a KSZ9031RNX-based board's manual, sitting between two sentences that
correctly name JL2121-N040I. Whoever first compiled this file (or the
ManualsLib copy it was reading) picked up that one sentence — probably a
keyword search for "PHY" — and missed the JL2121-N040I name stated twice
around it. The section below that used to be titled "Gigabit Ethernet /
RGMII to KSZ9031RNX" carried the same mistake forward into this project's
own notes, and from there into `spec/PROJECT_SPEC.md`. It took an actual
MDIO PHY-ID read on the physical board to catch it — matching text is not
enough evidence when the source document contradicts itself.

## Part number

- Board: ALINX AX7035B, $150, en.alinx.com product page.
- FPGA: **XC7A35T-2FGG484I** (stated on both the manual, Part 4, and the
  official product page's "Board Features" and "Product Selection Matrix").
  Confirmed as a real, distributor-stocked part (DigiKey, Mouser, LCSC,
  Newark) - NOT available in this machine's local Vivado 2024.2 part
  database by default (only `xc7a35tifgg484-1L` is installed for the
  industrial/FGG484 combination). Requires Vivado's "Add Design Tools or
  Devices" installer to add the -2I speed grade pack.

## Clock (Manual Part 5, page 11)

| Signal | FPGA Pin | Bank | Notes |
|---|---|---|---|
| 50 MHz oscillator (Sitime active crystal) | **Y18** | 14 | Global clock (GCLK) capable pin |

## User LEDs (Manual Part 21, page 42)

| Signal | FPGA Pin | Bank |
|---|---|---|
| LED1 | F19 | 16 |
| LED2 | E21 | 16 |
| LED3 | D20 | 16 |
| LED4 | C20 | 16 |

Active-low: "When the IO voltage connected to the user LED is configured low
level, the user LED lights up... configured as high level, the user LED will
be extinguished."

Board also has PWR (power indicator) and 2 USB-UART activity LEDs - manual
gives no pin assignment for these (not user-controllable).

## Gigabit Ethernet / RGMII to the JL2121(D) (real manual pages 13-15)

| Signal | FPGA Pin | Description |
|---|---|---|
| E1_GTXC | L14 | RGMII transmit clock |
| E1_TXD0 | J21 | Transmit Data bit0 |
| E1_TXD1 | M20 | Transmit Data bit1 |
| E1_TXD2 | L18 | Transmit Data bit2 |
| E1_TXD3 | L20 | Transmit Data bit3 |
| E1_TXEN | L19 | Transmit enable (RGMII TX_CTL) |
| E1_RXC | K18 | RGMII receive clock |
| E1_RXD0 | K19 | Receive Data bit0 |
| E1_RXD1 | M15 | Receive Data bit1 |
| E1_RXD2 | J17 | Receive Data bit2 |
| E1_RXD3 | J20 | Receive Data bit3 |
| E1_RXDV | M21 | Receive data valid (RGMII RX_CTL) |
| E1_MDC | K17 | MDIO management clock |
| E1_MDIO | K16 | MDIO management data |
| E1_RESET | L15 | PHY reset signal |

All 15 pins re-checked against `AX7035B_UG.pdf` page 14-15's own tables and
figure 8-1 (the FPGA-to-PHY schematic block) — every value above matches
what the ManualsLib reconstruction already had. Confirmed BANK=15 via Vivado
(`get_property BANK [get_package_pins ...]` against xc7a35tifgg484-1L,
package pinout is identical across FGG484 speed grades). This is the full
pin set `constrs/pins.xdc` uses for R13/R14/R16.

### PHY strap configuration (real manual page 14, Table 8-1 "PHY芯片默认配置值")

New in this update — not something the ManualsLib reconstruction had, since
it was a table only visible in the actual figure/table layout:

| Strap pins | Function | Configured value |
|---|---|---|
| RXD3_ADR0, RXC_ADR1, RXCTL_ADR2 | MDIO/MDC PHY address | **PHY Address = 001 (binary) = 1** |
| RXD1_TXDLY | TX clock delay | **2 ns delay enabled** |
| RXD0_RXDLY | RX clock delay | **2 ns delay enabled** |

Consequences:

- **`rtl/gem_mdio.v`'s `PHY_ADDR` parameter was defaulted to 0**, described
  in its own header as a guess. It is now `PHY_ADDR = 1`, matching the strap.
  B.5's original PHY-ID read at address 0 still worked because the JL2121(D)
  datasheet's strap table documents address 0 as a standing broadcast
  address the PHY answers regardless of its strapped address — so 0 worked
  by broadcast, not because it was the right guess.
- **Both RXDLY and TXDLY are populated to add their 2 ns option**, not left
  at 0 ns. This is the concrete input the RGMII timing budget re-derivation
  (`Documents/RGMII I-O Timing Derivation.md`, `Documents/RX Clock Deskew
  Design.md`) needs against the JL2121(D)'s own AC timing (datasheet Chapter
  4.7, `DS009-JL2121(D)-v1.09-Preliminary`) — that re-derivation is not done
  yet, but it no longer needs a schematic to start: the strap states are
  known.

## Power / bank voltage (real manual pages 6-9, Part 3 "电源" and Part 4 "FPGA")

- V_CCINT = 1.0V (FPGA core), V_CCBRAM = 1.0V, V_CCAUX = 1.8V.
- BANK34 (DDR3) = 1.5V.
- "the voltage of other BANK is 3.3V" - general rule, applies to bank 14
  (clock) and bank 15 (Ethernet) with no exceptions noted.
- **BANK16 (LEDs, keys) VCCO = 3.3V, confirmed.** The real manual's power
  section names the specific LDO: "one LDO SPX3819M5-3.3 produces the VCCIO
  supply, mainly powering the FPGA's BANK16" (page 7), and page 9 restates it
  directly: "other banks' voltage are all 3.3V, among which BANK16's VCCO is
  supplied by an LDO [and] can be changed by replacing the LDO chip." The
  LDO's own part number (`-3.3` suffix) is a fixed-3.3V output part. This
  used to be an assumption inferred from a general rule plus corroborating
  demo constraints; the real manual states it for BANK16 by name.

## Reset key, user keys and USB-UART (confirmed against the schematic)

The manual's text has none of these. Part 20 (keys, page 40) and Part 13 (USB to
serial port, page 28) both describe the hardware in prose and leave the pin
numbers in schematic figures, which ManualsLib's text layer does not carry -
re-checked page by page in August 2026, so the gap is real rather than an
extraction abandoned too early.

They are, however, in ALINX's own example projects, which a third party has
mirrored along with the board CD's schematic and documents:
<https://github.com/BLANK2077/AX7035> - `SRC/01_led_test`, `SRC/02_key_test`
and `SRC/04_uart_test`, each with a `constrs_1/new/*.xdc`.

| Signal | FPGA Pin | Bank | PIN_FUNC | Source demo |
|---|---|---|---|---|
| `rst_n` (reset key) | **F20** | 16 | IO_L18N_T2_16 | all three |
| `uart_rx` (FPGA input, from CP2102) | **G15** | 15 | IO_L2P_T0_AD8P_15 | 04_uart_test |
| `uart_tx` (FPGA output, to CP2102) | **G16** | 15 | IO_L2N_T0_AD8N_15 | 04_uart_test |
| KEY1 | M13 | 15 | IO_L20P_T3_A20_15 | 02_key_test |
| KEY2 | K14 | 15 | IO_L19N_T3_A21_VREF_15 | 02_key_test |
| KEY3 | K13 | 15 | IO_L19P_T3_A22_15 | 02_key_test |
| KEY4 | L13 | 15 | IO_L20N_T3_A19_15 | 02_key_test |

**Confirmed against the schematic itself.** The same mirror carries the board
schematic (`SCH/SCH.pdf`, 18 sheets, ALINX, Rev 1.0, 13 April 2018), and every
pin above was read back out of it: `UART_TXD` on **G16** and `UART_RXD` on
**G15** (sheet 3), the reset key's net `RESET` on **F20** (sheet 4, pin function
`IO_L18N_T2_16`, which is what Vivado independently reports for F20), and
`KEY1`-`KEY4` on M13/K14/K13/L13. **The direction question is settled too**:
ALINX's own `04_uart_test` declares `output uart_tx` and constrains it to G16, so
this design transmits on G16 and no swap-and-retry is needed at bring-up.

**The schematic also confirms every Ethernet pin in the table above** - E1_MDC
K17, E1_RESET L15, E1_GTXC L14, E1_RXC K18, E1_RXD0 K19, E1_RXD3 J20, E1_TXD0
J21, E1_TXD1 M20, E1_TXEN L19 read unambiguously, and the rest resolve to the
same values this document already had. That matters more than the two new pins:
those fifteen came from ManualsLib's text extraction and had never been checked
against anything, and they are the pins the entire design talks through.

*The PDF is deliberately not committed here.* Its sheets are stamped "ALINX
Confidential", so this repository cites it rather than redistributing it; it is
in the mirror above, and ALINX send their own copy after purchase.

**Why the demo constraints were worth using even before that.** Three reasons,
kept because the reasoning is the reusable part:

1. **It agrees with what was already known.** The same XDC files carry
   `sys_clk` = Y18 and the four LEDs at F19/E21/D20/C20 - five pins this document
   already had from the manual's own text, all five matching exactly. A file
   describing some other board would have disagreed on at least one of them.
2. **Every pin is real.** All twelve were queried against the
   `xc7a35tifgg484-1L` package database in Vivado: valid package pins, sensible
   banks, and `G15`/`G16` are the `L2P`/`L2N` halves of one differential pair,
   which is exactly how two signals routed together to a UART bridge land.
3. **It corroborates the bank-16 voltage assumption above.** The demos constrain
   F19-C20 and F20 as `LVCMOS33`, which is what `constrs/pins.xdc` assumed and
   flagged as unverified.

One caution survives all of it: **this is a third-party mirror, not ALINX's own
download.** A.2's rule stands - trust the physical board over any document the
moment they disagree. What the mirror has going for it is that three independent
things now agree (the manual's text, ALINX's demo constraints, and the
schematic), and nothing disagrees.

## Still open, now that the real manual is in hand

- **The RGMII AC timing budget.** B.1b's numbers (1.2 ns RX default delay,
  the setup/hold windows, PHY reset `tSR`) are KSZ9031RNX datasheet figures
  applied to a JL2121(D) board. The strap inputs that budget needs are now
  known (RXDLY/TXDLY both +2 ns, above), but the budget itself has not been
  re-derived from the JL2121(D)'s own AC specifications
  (`DS009-JL2121(D)-v1.09-Preliminary` Chapter 4.7). This gates trusting
  R14/R20's margin numbers and the RX deskew MMCM's phase-centring target.
- Nothing else in this file is an open assumption any more — Bank 16's
  voltage, the full RGMII/MDIO/UART/key pinout, the PHY address, and the
  RXDLY/TXDLY strap states are all confirmed directly from
  `Manuals/AX7035B_UG.pdf`.
