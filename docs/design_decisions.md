# Design Decisions

Every "why not X" answered, per master spec §13. Decisions here are binding
until superseded by a new entry — don't relitigate in prose elsewhere.

---

## D1 — Reuse ALINX's Ethernet MAC datapath; do not hand-write one

**Decision:** the market-data ingress/egress MAC (`[B] eth_mac_rx`, `[K] eth_mac_tx`
in §3.1) is ALINX's own hand-written RTL from their AX7035B reference tree
(`docs/refs/AX7035/SRC/21_ethernet_test/.../mac/`: `mac_top.v` and its
children — `mac_rx.v`, `mac_tx.v`, `arp_rx/tx.v`, `ip_rx/tx.v`, `udp_rx/tx.v`,
`crc.v`, `arp_cache.v`, `util_gmii_to_rgmii.v`), vendored into
`rtl/vendor/alinx_mac/` with attribution, not rewritten from scratch.

**Why:** writing and timing-closing an RGMII MAC from scratch is a large,
high-risk sub-project in its own right (CDC, IDELAY tuning, CRC, ARP) that is
orthogonal to what this project actually demonstrates (parsing, book state,
risk gating, ML-in-path). ALINX ships a working, board-matched MAC; reusing it
converts a multi-week risk into an integration task.

**Consequence — the MAC boundary is not what the spec assumed.** It is
neither AXI4-Stream nor raw GMII (§17 open question 1's two hypothesized
options were both wrong):

- **TX (our `order_builder` → MAC):** byte-push into a FIFO, not a ready/valid
  stream — `ram_wr_data[7:0]` / `ram_wr_en` (push, backpressure via
  `almost_full`), `udp_send_data_length`, `udp_tx_req` (one-shot), `mac_send_end`.
- **RX (MAC → our `frame_classifier`/`md_parser`):** a whole-frame-buffered
  dual-port RAM, not a stream at all — `udp_rec_ram_rdata[7:0]` read at an
  address **we** drive (`udp_rec_ram_read_addr[10:0]`), `udp_rec_data_length`,
  `udp_rec_data_valid` (pulses once the complete, already-CRC/checksum-verified
  UDP payload is sitting in the RAM).

A new adapter module, `rtl/eth_mac_if.v`, converts this into the byte-stream
(`valid`/`last`) shape the rest of the datapath expects: on RX it walks the
RAM address counter once `udp_rec_data_valid` pulses and re-presents bytes as
a synthetic stream; on TX it drains `order_builder`'s frame into the push
interface. This is new work at S2/S8, not a drop-in.

**Bonus simplification:** because `udp_rx.v` already strips Ethernet+IP+UDP
headers and verifies the IPv4 header checksum before asserting
`udp_rec_data_valid`, `frame_classifier` does not need to re-parse EtherType/
IPv4/UDP-port for `LINK_MODE=1` — it only needs to check `udp_rec_data_length`
is a multiple of 16 (FR-5) and hand the payload to `md_parser`. This shrinks
`frame_classifier`'s scope for the UDP path; keep the from-scratch EtherType/
IPv4 parse in reserve only for a possible raw-mode passthrough (see D3).

Resolves §17 open questions **1** and **2**.

---

## D2 — Single clock domain = the MAC's recovered RX clock

**Decision:** the entire engine (`md_parser` through `order_builder`, CSR,
histogram — everything) runs on `gmii_rx_clk`, the RGMII receive clock
recovered from the link partner and brought in through a `BUFG` in
`util_gmii_to_rgmii.v`. `sys_clk` (50 MHz board oscillator) is retained only
for PHY reset sequencing and MDIO.

**Why:** in ALINX's MAC, `gmii_tx_clk` is wired directly from `gmii_rx_clk`
(`assign gmii_tx_clk_s = gmii_rx_clk;`) — there is no independent local
125 MHz TX reference and no CDC/FIFO at the MAC boundary. Fighting that
topology (adding a local free-running clock + async FIFOs) would be extra risk
for no benefit, since CLAUDE.md's hard conventions already commit this project
to a single 125 MHz clock domain. Using the recovered clock as *the* system
clock satisfies that convention for free and eliminates the CDC concern
entirely, at the cost of the datapath being unclocked (held in reset) until
link-up produces a stable `gmii_rx_clk` — which is true of any RGMII design
regardless of clocking topology.

**Follow-on:** add a reset synchronizer (built from the planned
`rtl/common/sync_2ff.v`) releasing our own logic's reset synchronously to
`gmii_rx_clk`, since `sys_clk`'s power-on reset counter is not in that domain.

---

## D3 — `LINK_MODE=1` (UDP) is the bring-up default, not raw Ethernet

**Decision:** reverses §17 open question 3's framing. `LINK_MODE=0` (raw
EtherType `0x88B5`) is deferred; hardware bring-up (S11) targets
`LINK_MODE=1` (UDP) from the start.

**Why:** the original "raw Ethernet is lower risk" reasoning assumed we'd be
hand-parsing frames ourselves, where skipping IP/UDP header logic is strictly
less code. That assumption no longer holds under D1 — ALINX's MAC only
understands ARP + IPv4 + UDP; a frame carrying our custom EtherType would be
dispatched by neither `arp_rx.v` nor `ip_rx.v` and silently dropped. Supporting
raw mode now means hand-modifying vendor RTL to add an EtherType-passthrough
path — more risk than the UDP path we get for free. `LINK_MODE=0` becomes a
sim-only mode (the Verilog testbench can drive whatever framing it likes) or a
later v1.x addition if a real need for it shows up; FR-2 stays in the spec but
is not gating S11.

**Consequence for FR-59 (UART fallback):** unaffected — it was always an
Ethernet-independent ingress path and remains the fallback if the MAC blocks
S8/S11, per §15's existing fallback note.

Resolves §17 open question 3 (reverses the stated default).

---

## D4 — Do not reuse ALINX's MIIM/MDIO block; write a small one of our own

**Decision:** `docs/refs/AX7035/.../miim/` (`miim.vhd`, `miim_control.vhd`,
etc.) is **not** vendored in. `rtl/common/mdio_ctrl.v` is a new, small,
hand-written MDIO sequencer covering exactly what bring-up needs.

**Why — two independent reasons, either one sufficient:**

1. **Licensing.** That VHDL block originates from
   [yol/ethernet_mac](https://github.com/yol/ethernet_mac) (confirmed via its
   source header and upstream `LICENSE.md`), under a modified BSD-3-Clause
   license with an added military-use-prohibition clause. That clause makes it
   **not OSI-approved / not a permissive license compatible with this repo's
   stated Apache-2.0 licensing** (§13) — the restriction would have to be
   preserved and disclosed verbatim for any redistribution, which is a poor
   fit for a public interview-facing repo (§18). Compounding this: ALINX's own
   copy already dropped the required `LICENSE.md`/attribution, so re-copying
   *their* copy would repeat a compliance gap rather than fix it.
2. **It has a real bug.** `miim_top` is instantiated everywhere with the
   default `MIIM_PHY_ADDRESS = 0`, but the strap table confirms this board's
   PHY sits at MDIO address `1` — every MDIO write in every ALINX example is
   addressed to a PHY that doesn't exist. (What it's writing *to* address 0
   turned out to matter more than expected — see D9: the chip at address 0
   isn't the one this block's comments assume, either.)

Since both issues have to be fixed regardless, and the fix is a small,
precisely specifiable state machine, writing our own is less work than
patching around someone else's licensing/correctness problems. See
`docs/contracts/mdio_ctrl.md` for the exact task handed off for this module —
**read D9 before trusting that contract's register/skew details**, several of
which were written against the wrong PHY and have since been corrected in the
module itself but not fully rewritten in the contract text.

**What we still take from ALINX's tree unmodified:** the RGMII pin map and
`create_clock` definitions in `top.xdc` (already folded into
`constraints/tob_pins.xdc`/`tob_timing.xdc`'s eventual RGMII additions), and
the PHY reset polarity/timing (`reset.v`'s pattern — active-low `e_reset`).
Both are PHY-agnostic facts about the board's pin wiring, not about which
chip is populated, so D9's correction doesn't touch them (independently
re-confirmed against the real chip's datasheet — see D9).

This decision doesn't correspond to a numbered open question — it's new
information the MAC-reuse investigation surfaced.

---

## D5 — Minimal, surgical patch to expose MAC RX error status

**Status: applied.** `rtl/vendor/alinx_mac/rx/udp_rx.v`, `mac_rx_top.v`, and
`rtl/vendor/alinx_mac/mac_top.v` carry this patch now (two new output ports
each, wiring `mac_rec_error` and a new `udp_checksum_error` port up to the
top level; `mac_rx.v` needed no change, `mac_rec_error` was already one of
its output ports).

**Decision:** two new output ports are added to the vendored (D1)
`mac_rx_top.v`/`udp_rx.v` — wiring out the `mac_rec_error` (CRC/FCS fail) and the
IP/UDP checksum-error bit that those files already compute internally but
currently only use to gate `udp_rec_data_valid` low. No other vendor logic
changes.

**Why:** confirmed behavior is frame suppression, not an error flag — a bad
frame simply never asserts `udp_rec_data_valid`, and the reason is invisible
at the boundary. FR-1 requires `err_fcs` to increment on FCS failure, and
§11.5's coverage goals require every error counter to actually be exercised.
Without this patch, `err_fcs` cannot be distinguished from "no traffic
arrived" and the counter is permanently zero regardless of real line errors —
a real spec-vs-hardware gap, not a nice-to-have. Exposing two already-computed
internal signals as new ports is minimal-risk (no change to MAC behavior,
only to its observability) compared to any alternative.

Resolves §17 open question 2 (see also D1).

---

## D6 — Board keys: four, not two; kill switch = KEY1

**Decision:** corrects the premise of §17 open question 4. The AX7035B has
**four** user keys (schematic net names KEY1–KEY4; a 2×2 block), confirmed
against `docs/refs/AX7035/SRC/02_key_test/key_test/constrs_1/new/key.xdc`'s
`key_in[0..3]` pin list:

| Signal | Pin | Assignment |
| :-- | :-- | :-- |
| `key_in[0]` | M13 (KEY1) | Kill switch (FR-46/47) |
| `key_in[1]` | K14 (KEY2) | Counter/latch clear |
| `key_in[2]` | K13 (KEY3) | Mode select (reserved; CSR-driven by default) |
| `key_in[3]` | L13 (KEY4) | Spare |

LEDs (same pin table, cross-checked against `01_led_test`/`02_key_test`):
`led[0]`=F19, `led[1]`=E21, `led[2]`=D20, `led[3]`=C20. `led[0]` is reserved
for kill-switch status (FR-47); `led[1..3]` assigned at S9 (link/heartbeat/
error).

All keys/LEDs are active-low per the reference examples' convention.

Resolves §17 open question 4.

---

## D7 — Reject reporting: counters-only gates S7; `0x11` frames are a stretch goal

**Decision:** the S7 ("Risk") milestone gate is met by gate counters alone.
The `0x11` diagnostic frame path (FR-44, already `cfg_reject_report=0` by
default) is implemented after S7's gate passes, not as part of it.

**Why:** FR-44 already makes this opt-in and off by default specifically so
diagnostics can't influence measured behavior — treating its encoder as
optional-until-later is consistent with that intent, and keeps S7 focused on
the nine gates and their counters, which is what §11.5's coverage goals
actually require.

Resolves §17 open question 5.

---

## D8 — Vendor IP cores need regenerating under Vivado 2024.2

**Decision:** before `rtl/vendor/alinx_mac/` is wired into anything past the
S0 skeleton, regenerate its `.xci` dependencies (`clk_wiz` 5.4, `fifo_generator`
13.2, `blk_mem_gen` 8.4, `ila` 6.2 — all Vivado 2016–2018-era) under 2024.2 via
Vivado's IP Status / Upgrade Selected IP flow. Not blocking S0 (today's
skeleton touches none of them); tracked as an S2 checklist item.

---

## D9 — Correction: the PHY is JLSemi JL2121(D), not Micrel KSZ9031RNX

**What was wrong:** CLAUDE.md, the master spec's header table, PREREQUISITES.md,
and D4 above all stated the PHY as Micrel KSZ9031RNX — and so did the ALINX
schematic in `docs/refs/AX7035/SCH/SCH.pdf` ("PAGE10 Ethernet PHY" names it
explicitly). Every source agreed, so nothing in this session's own research
caught it. What broke the agreement: `docs/refs/AX7035B_pinout_notes.md` — a
note file already sitting in `docs/refs/` from unrelated prior work on this
exact board — records that an actual MDIO PHY-ID register read on the physical
board returned `0x937c4032`, which decodes to JLSemi's OUI, not Micrel's. That
file even explains *how* the wrong chip name got this far: ALINX's real user
manual (`AX7035B_UG.pdf`, not the ManualsLib mirror or the nested demo repo's
schematic) names the JL2121-N040I twice on the same page that a boilerplate
sentence describing KSZ9031RNX's *feature set* got pasted in from a different
board's manual — a keyword search for "PHY" would land on that one sentence
and miss the two correct chip names around it. The nested demo repo's
schematic in this checkout is simply the older/wrong-chip version of ALINX's
reference material; it wasn't cross-checked against `docs/refs/AX7035B_pinout_notes.md`
before D1–D8 were written, which is the actual process failure here — that
file was one `ls docs/refs/` away the whole time.

**Impact, checked item by item rather than assumed:**

- **`rtl/vendor/alinx_mac/` (D1) and the single-clock-domain decision (D2):
  unaffected.** RGMII is a standard interface; the MAC talks RGMII regardless
  of which PHY is on the other end, and `gmii_tx_clk = gmii_rx_clk` is a fact
  about ALINX's MAC RTL, not about the PHY.
- **`LINK_MODE`/reject-reporting/board-key decisions (D3, D6, D7): unaffected.**
  None depend on PHY identity.
- **Pin assignments in `constraints/tob_pins.xdc` (sys_clk, rst_n, LEDs,
  keys): unaffected.** `docs/refs/AX7035B_pinout_notes.md` independently
  re-derived the full RGMII/MDIO/LED/key pinout from the real manual and
  schematic and it matches what this repo already had, pin for pin.
- **`rtl/common/mdio_ctrl.v`'s three direct clause-22 writes (registers
  0/4/9): unaffected, re-verified against the actual JL2121(D) datasheet
  (`docs/refs/JL2121_datasheet.pdf`, pulled via `pdfplumber` after a first
  pass with `pdftotext` produced a badly column-scrambled table that looked
  like it disagreed — worth remembering that lesson before trusting a quick
  text dump of a multi-column PDF table). Registers 0 (BMCR), 4 (ANAR), and 9
  (GBCR) have bit-identical layouts for the fields this module writes on both
  chips — that's IEEE 802.3 clause 22 standardization doing its job, not
  luck. `0x9140`/`0x0141`/`0x0200` stand unchanged.
- **`rtl/common/mdio_ctrl.v`'s four MMD/pad-skew indirect writes: removed
  entirely, not re-targeted.** These were Micrel's proprietary "MMD device 2,
  registers 4/5/6/8" mechanism, accessed through a clause-45-over-22 portal
  unique to that vendor's PHYs. The JL2121(D)'s register map (datasheet §6.2)
  has no equivalent — it uses an entirely different paged-register scheme
  (`PAGSR`, register `0x1F`) for its own vendor-specific registers, and no
  register anywhere in its map does RGMII pad-skew tuning. That's because this
  chip does RX/TX clock delay via **hardware strap pins** (`RXD0`/`RXDLY`,
  `RXD1`/`TXDLY`, sampled at power-on reset), not software registers —
  `docs/refs/AX7035B_pinout_notes.md` confirms both are already strapped to
  +2ns on this board. There is nothing for firmware to configure here; the
  four-write MMD section was deleted rather than replaced.
- **New requirement the JL2121(D) datasheet states and the old design
  didn't account for:** after the register-0 software-reset write (bit 15),
  "need to delay 10ms de-assert time for chip steady" before the chip is
  reliable. `mdio_ctrl.v` now holds `busy` through that delay before pulsing
  `done`, rather than completing immediately after the last MDIO frame.

**What did not change:** the licensing/PHY-address reasoning in D4 for not
reusing ALINX's borrowed MIIM block — that was about the *code*, not the
target chip, and stands regardless of which PHY it would have mismanaged.

**Process note, for next time:** `docs/refs/AX7035B_pinout_notes.md` and
`docs/refs/JL2121_datasheet.pdf` were sitting at the top level of `docs/refs/`
the entire time D1–D8 were written; the investigation that produced D1–D8 only
ever looked inside `docs/refs/AX7035/` (the nested vendor demo repo). A plain
`ls docs/refs/` before trusting a nested vendor tree as ground truth would
have caught this before any RTL was written, not after.

---

## D10 — `eth_mac_if.v`: buffer-and-pace the TX side, don't stream it

**Decision:** `rtl/eth_mac_if.v` is implemented. RX is a straightforward
two-stage address-walk (present an address, capture the RAM's registered
response one cycle later) triggered on `udp_rec_data_valid`'s rising edge.
TX does **not** expose a byte-stream to `order_builder.v`; it exposes a
fixed-size `tx_payload` bus (the whole 16-byte record presented at once) plus
`tx_start`/`tx_busy`, and paces the actual `ram_wr_data`/`ram_wr_en`/
`udp_tx_req` sequence itself.

**Why not a streaming TX interface:** `rtl/vendor/alinx_mac/tx/udp_tx.v`
computes the UDP checksum *live* off `ram_wr_data` while it's also being
written into the TX FIFO — sampling it at a fixed cycle offset from
`udp_tx_req`'s assertion, not from anything `order_builder` would naturally
expose (no ready/valid, no start-of-frame marker). Get that offset wrong and
every outgoing order carries a corrupted UDP checksum — silently dropped by
the host's network stack, no error anywhere in this design to notice it.
Making `order_builder.v` itself responsible for that exact cycle-lockstep
timing would leak vendor-internal timing into a module that has no way to
verify it independently. Buffering the payload here and pacing it out
internally means the timing-critical part is verified once, in
`eth_mac_if.v`, against the real vendor logic.

**How the timing was derived and checked — not assumed from a spec table.**
Traced `rtl/vendor/alinx_mac/tx/udp_tx.v`'s `ck_state` FSM by hand: `checksum_cnt`
resets to 0 on entering `HEADER_CHECKSUM` and again on entering `GEN_CHECKSUM`
(it does **not** carry across that transition — the first read of this file
assumed it did, which would have been wrong), `HEADER_CHECKSUM` lasts exactly
9 cycles, and `GEN_CHECKSUM` samples `{ram_wr_data_d1, ram_wr_data_d0}` — a
2-cycle-delayed pair — starting from its own first cycle. Working through
that delay chain gives: payload byte 0 must land on `ram_wr_data` exactly 9
cycles after the cycle `udp_tx_req` is asserted, then one byte per cycle,
back to back (`TX_HEADER_DELAY` in `eth_mac_if.v`).

**That derivation was then verified, not trusted.** No real simulation model
exists locally for the three Xilinx IP cores this vendor code depends on
(`udp_tx_data_fifo`, `udp_checksum_fifo`, `udp_rx_ram_8_2048` — only
synthesis-only black-box stubs are present; see
`tb/sim_models/xilinx_ip_sim_models.v`'s header for why and what was written
instead: plain, standard FIFO/dual-port-RAM behavioral models, clearly
marked simulation-only, matching each core's own `.veo` port list).
`tb/tb_eth_mac_if_tx.v` instantiates the **real, unmodified** vendored
`mac_top.v` (D1) together with `eth_mac_if.v`, drives a known payload through
it, captures the actual transmitted wire bytes, and compares the UDP
checksum against an independently-computed RFC 768 checksum written from
scratch in the testbench. It matched on the first payload tried with
`TX_HEADER_DELAY = 9` — the derivation was right, but the point is that this
was checked against the real control logic rather than shipped on the
strength of the trace alone.

**Incidental finding from that same testbench, not a bug:** the vendored
`udp_tx.v` pads any UDP frame whose header+payload totals under 26 bytes up
to 26 bytes with trailing zeros (standard Ethernet minimum-frame-size
padding — our order records are 8-byte UDP header + 16-byte payload = 24
bytes, so this always fires). The UDP header's own length field still
correctly reports 24, so a real receiver's `recvfrom()` never sees the
padding — only a raw packet capture would. Worth knowing before anyone stares
confused at 2 extra bytes on a wire trace during S11 bring-up.

`tb_eth_mac_if_rx.v` covers the RX side independently, against a mocked RAM
boundary rather than the full vendor RX pipeline — appropriately proportionate
to that side's much lower timing risk (a straightforward address-walk, not a
cycle-locked checksum engine).

---

## D11 — Bad-length frames: discard whole, not just the trailing remainder

**Decision:** `eth_mac_if.v` gained two new outputs, `frame_start` (pulses
once per frame, including a genuinely empty one) and `rx_len` (the
authoritative length, valid the same cycle) — both available *before* any
payload byte streams out on `rx_data`. `frame_classifier.v` uses them to
check `rx_len` up front and decide whether to forward anything for
that frame at all. `golden_model.py`'s `parse_frame_payload` discards the
whole frame on a bad length (`[], True`), matching FR-5's literal wording.

**Why this needed two passes to get right.** The first version of
`parse_frame_payload` also discarded the whole frame, but while designing
`md_parser.v`'s interface a real objection came up: a genuinely streaming
parser can't know a frame's *total* length until it ends, and FR-53 times
each message at "the last byte of a message entering the parser" — implying
complete 16-byte groups are forwarded as they complete, not held back
pending the frame's fate. Under that reasoning, "discard whole" isn't
physically realizable — messages already forwarded three groups ago can't be
un-forwarded — so `parse_frame_payload` was changed to discard only a
trailing incomplete remainder, keeping whatever complete messages came
before it.

That reasoning is correct in general and wrong for this project specifically,
which is what makes it worth recording rather than just quietly fixing:
D1 already committed this project to reusing a vendor MAC that buffers the
*entire* frame and computes its length before `udp_rec_data_valid` ever
asserts. `eth_mac_if.v` was already sitting on that length — it just wasn't
exposed yet. Once `frame_start`/`rx_len` were added to surface it,
`frame_classifier.v` genuinely can decide before forwarding a single byte,
so the "can't know the length in time" premise doesn't hold here. Reverted
back to whole-frame discard before `md_parser.v` got designed against the
wrong assumption, which would have made the two disagree with each other.

**Consequence for `md_parser.v`'s design:** it doesn't need to infer a bad
length by counting bytes and reasoning about where `rx_last` fell — it can
just read `rx_len` directly at `frame_start` and know immediately
whether to expect a byte stream at all.

Also fixes a real gap `frame_start`/`rx_len` incidentally closes: a
0-byte UDP payload (T05's third case) previously produced *no signal
whatsoever* from `eth_mac_if.v` — not even `rx_last` — since there was no
byte to walk the RAM for. Without a length-independent "a frame happened"
pulse, that case would have been invisible downstream. `tb_eth_mac_if_rx.v`
now covers it directly.

---

## D12 — Golden model: check `msg_type`/`flags` before the symbol filter, not after

**Status: applied**, `sim/golden_model.py`. **Decision:** `GoldenModel.process_message`
now validates `msg_type`/`flags` (FR-8/FR-9) *before* the symbol filter
(FR-7), reversing their previous order. Sequence gap/dup tracking (FR-10/11/12)
is unaffected — it still runs first, before either check (that part of the
ordering was already correct and already tested; see the comment above it in
`golden_model.py`).

**Why.** Found while defining the exact interfaces for the S3 contracts
(`symbol_filter.v`, `seq_monitor.v`) — before any S3 test exercised the
combination that exposes it. `md_parser.v` (S2, already committed,
`docs/contracts/md_parser.md`) is the module that checks `msg_type`/`flags`,
and it sits *upstream* of `symbol_filter.v` in the pipeline (master spec
§3.1's block diagram: `md_parser → symbol_filter → seq_monitor →
tob_engine`). By construction, a message with an undefined `msg_type` or a
reserved `flags` bit never gets a `msg_valid` pulse out of `md_parser.v` — it
never reaches anything downstream, including a symbol filter. There is no
way to build a `symbol_filter.v` that sees such a message first; `md_parser.v`
already dropped it. The old golden-model order (filter, then type/flags)
was therefore not realizable by the actual chosen architecture — it only
produces a different result than the RTL for one specific corner case (a
message that is simultaneously on an unwatched `symbol_id` **and** has a bad
`msg_type`/reserved `flags` bit), which is exactly why no S1/S2 test caught
it: `sim/test_golden_model_handcase.py`'s original 20 messages never combined
those two conditions on one message.

**Consequence:** for that corner case, `err_msg_type`/`err_flags` now
increments and `cnt_msgs_filtered` does not — matching what `md_parser.v`
actually does. §10's invariant (`cnt_msgs_rx = filtered + accepted +
Σerr_*`) still holds; only which bucket a doubly-bad message lands in
changed. `sim/test_golden_model_handcase.py` messages 21–23 cover the
corner case directly (both combinations, plus a control case confirming
plain filtering is unaffected) — 23 messages total now, was 20.

**Consequence for S3 contracts:** `symbol_filter.v` only ever needs to
handle `md_parser.v`'s `msg_valid`-gated output (type/flags already clean by
construction) — it does not need any special-case interaction with
`err_msg_type`/`err_flags`. `seq_monitor.v` is the one exception: FR-10's
"per feed" sequence tracking must still run on every completed message
regardless of `msg_valid`, so it consumes `msg_valid | err_msg_type |
err_flags` from `md_parser.v` as its "a message completed, `msg_seq_num` is
valid" trigger (all three are registered fields in `md_parser.v`,
unconditionally latched every message regardless of type/flags validity —
confirmed by reading `rtl/md_parser.v` directly, not assumed). See
`docs/contracts/seq_monitor.md` §1 for the exact reasoning as handed to the
implementer.

Not a resolution of a numbered §17 open question — new information the S3
contract-writing process surfaced, the same way D11 was surfaced by
designing `md_parser.v`'s interface.

---

## D13 — F5/F7 window semantics, pinned for the FPGA side

**Status: applied**, `sim/feature_golden.py` (new file) +
`sim/test_feature_golden_handcase.py` (new file). **Decision:** F5 (update
rate) and F7 (short-term volatility) share **one** W-deep sliding window per
symbol, which advances on **every accepted event of any `msg_type`**
(QUOTE/CLEAR/TRADE/HEARTBEAT), not only book-modifying ones. Each slot
records `(is_update, abs_mid_delta)` for the event that produced it —
`is_update` true only for QUOTE/CLEAR (FR-19); `abs_mid_delta` is that
event's `|F1|`, which is 0 for TRADE/HEARTBEAT (mid does not change then)
and 0 for the first event after a reset/clear. F5 = count of `is_update`
slots in the window; F7 = sum of `abs_mid_delta` over the window. The
*current* event's own contribution is included in that same event's output
(window read as "as of and including now").

**Why this needed a decision at all:** `ml_engineer_brief.md` §4 states
outright that window inclusion is unresolved and must be pinned by whoever
builds against it ("Decide whether the current event is included in the
window or not, and write it down") — the master spec's own feature table
(§5.3) doesn't fix it either. This blocks writing a correct
`feature_extractor.v` contract (T27 needs a bit-exact reference to check
against), so it had to be resolved before, not during, S3 contract writing.

**Why "every event", not "only book-modifying events":** F5 is described as
"update rate... in the last W events." If the window only ever held
book-modifying events, F5 would trivially equal `min(events-seen, W)` —
saturated almost immediately and constant thereafter, which makes "clipped"
a pointless thing for the spec to call out. Reading "events" as *all*
accepted traffic (with F5 counting the book-modifying fraction of it) is the
only reading that makes F5 a real, varying signal — heavier trade/heartbeat
traffic relative to quotes correctly lowers it.

**A book-clear (FR-16) resets `prev_bid`/`prev_ask`/the window to the same
all-zero state as power-on, then is itself treated as exactly "the first
event after reset"** (same F1=F3=F4=0 rule `ml_engineer_brief.md` §4 already
states for post-reset). This was the simplest self-consistent reading of
"clear resets the feature history to the initial state" and needed no
separate special case.

**FR-26 (forcing the classifier input to a safe state on an invalid/crossed
book) is explicitly not this module's job** — `feature_extractor.v` computes
raw features mechanically from whatever `tob_engine` state it's given, no
masking. This keeps the S3 contract's scope exactly matching T27's covered
FRs (FR-20/21); FR-26's forcing belongs to a later ML-path stage
(`ml_policy.v` or similar, not built yet).

**Raw feature width: 32-bit** (unsigned for F0/F5/F7, signed two's-complement
for F1/F2/F3/F4/F6) for every feature, uniformly. Not an arbitrary choice —
it's the one piece of concrete width evidence already in the spec: §9's
`ML_OFFSET_0..7`/`ML_SHIFT_0..7` registers, which subtract from and shift a
raw feature before normalization, are already declared 32-bit.

**Window depth `W` is an elaboration-time parameter for this contract, not
the runtime `ML_WINDOW` CSR register (§9) yet.** FR-32 does list window `W`
among the parameters required to eventually be runtime-configurable, but
that requirement sits in §6.5 (ML classifier), not §6.4/T27's scope, and no
S3 test exercises changing `W` mid-stream. Building true runtime
reconfigurability now — a window whose *size*, not just contents, changes
live — would mean either re-deriving F5/F7 from scratch on every possible
configured depth simultaneously or an incremental running sum that goes
stale the instant `W` changes; real complexity with no test yet demanding
it. Deferred to whichever milestone first wires `csr_block.v`'s `ML_WINDOW`
register into this module (S6), matching this project's own "don't build
ahead of a gating test" convention. `sim/feature_golden.py`'s
`FeatureTracker` already takes `window` as a fixed constructor argument, not
a runtime-mutable field, so no rework was needed there.

**A real RTL pitfall this decision sidesteps, worth recording anyway since
it's the reason recompute-from-scratch was chosen over the more "obvious"
efficient design:** a sliding-window sum's natural efficient implementation
is *incremental* — add the newest value, subtract the value falling out of
the window — which breaks under per-cycle saturation: once a contribution
has been clamped on the way in, its original value is gone and can't be
correctly subtracted back out later. With `W` fixed at elaboration time,
`docs/contracts/feature_extractor.md` sidesteps this class of bug entirely
rather than working around it: F5 (popcount) and F7 (sum, saturated only at
its own 32-bit output, nowhere internally) are both **recomputed from
scratch** over the full `W`-deep window on every accepted event, via a plain
adder/popcount tree (`W` ≤ 32, so ≤5 tree levels — cheap, and FR-23-legal
since a tree is still only adds). No subtraction, so no stale-saturation
bug to avoid. See `docs/contracts/feature_extractor.md` §2.6 for the full
reasoning as handed to the implementer.

Not a resolution of a numbered §17 open question — new information the S3
contract-writing process surfaced, same as D11/D12.

---

## D14 — Golden model: FR-15's price-preservation was not actually implemented

**Status: applied**, `sim/golden_model.py`. **Decision:** `GoldenModel.process_message`'s
`MSG_QUOTE` handling now writes `bid_price`/`ask_price` only when the
message's `quantity != 0`; the `quantity`/`valid` writes stay unconditional.

**Why.** Found the same way as D12/D13 — while pinning down the exact
per-field behavior `tob_engine.v` needs for T10 (`FR-15`'s explicit S3 gate).
FR-15's text is explicit: quantity=0 "clears that side's `valid` **without
altering stored price**." The golden model's code, before this fix,
unconditionally overwrote `bid_price`/`ask_price` with `msg.price` on every
`QUOTE`, regardless of quantity — i.e. it did not actually implement the
"without altering stored price" half of FR-15 at all. No existing test
caught it because no S1/S2 hand-case ever sent a `quantity=0` `QUOTE`.
`sim/test_golden_model_handcase.py` messages 24–25 now cover it directly: a
`qty=0` quote carrying a deliberately wrong price (`9999`) must leave the
side's stored price unchanged, and a subsequent normal (non-zero-quantity)
quote on the same side must still update price normally (confirming the fix
didn't break FR-14's ordinary case).

**Consequence for `tob_engine.v`:** the price register write for a side must
be gated on `msg_quantity != 0`, not written every `QUOTE` cycle — an easy
detail to drop since "replace price+qty for the addressed side" (FR-14) reads
like an unconditional pair-write until FR-15's exception is read carefully.
See `docs/contracts/tob_engine.md` §2.2 for the exact wording handed to the
implementer.

Not a resolution of a numbered §17 open question — new information the S3
contract-writing process surfaced, same as D11/D12/D13.

---

## D15 — `signal_engine.v`'s imbalance shift must use wide-precision arithmetic, not a naive 32-bit shift

**Decision:** `rtl/signal_engine.v` (contract:
`docs/contracts/signal_engine.md`) must compute `ask_qty << cfg_imb_shift`
and `bid_qty << cfg_imb_shift` in a wide (≥35-bit) intermediate — zero-pad
`bid_qty`/`ask_qty` by `cfg_imb_shift`'s maximum width (3 bits, per the CSR
map's `IMB_SHIFT: 0-3`) before shifting — rather than a plain 32-bit
left-shift that silently drops bits off the top.

**Why.** FR-37 states buy and sell firing simultaneously is "impossible by
construction." That claim is only actually true under `sim/golden_model.py`'s
arithmetic, which uses Python's unbounded integers — `book.ask_qty <<
self.cfg.imb_shift` never overflows there, for any quantity. A plain 32-bit
hardware shift is not equivalent: `bid_qty = ask_qty = 0x80000000,
imb_shift = 1` makes both `ask_qty << 1` and `bid_qty << 1` wrap to `0` in
32 bits, so `bid_qty > (ask_qty << 1)` and `ask_qty > (bid_qty << 1)` **both**
read true — a spurious conflict the golden model would never produce for
that same input, verified empirically (not just reasoned about) before
writing this entry. Quantities anywhere near `2^31` are unrealistic for this
project's synthetic feed, so a random-stimulus soak test is very unlikely to
ever land exactly here — but "unlikely to be hit by random stimulus" is a
worse standard than "actually bit-exact," which is this project's stated
hard requirement (S11.1), and the fix (widen one intermediate by 3 bits)
costs nothing. Found and fixed before any RTL existed, same as D12-D14.

**Consequence:** under the wide-precision design, FR-37's "impossible by
construction" is genuinely true in the RTL too — `err_signal_conflict` is
correctly unreachable via any honest combination of `bid_qty`/`ask_qty`
inputs, matching the golden model. §5's out-of-scope note in
`docs/contracts/signal_engine.md` explains why this makes the conflict path
untestable via ordinary black-box stimulus, and what to do about it (a
`force`-based Icarus test targeting the internal `buy_ok`/`sell_ok` wires
directly, isolated from the input-driven computation that can no longer
produce that state).

**A second, independent reason `crossed` must be its own explicit AND term
(not implied by the spread comparison):** `ask_price - bid_price`, computed
as a plain unsigned 32-bit subtraction, **underflows to a huge positive
number** when the book is crossed (`bid_price >= ask_price`) — a crossed
book can look like it has an enormous spread if nothing else guards against
it. FR-35/36 already list "not crossed" as an independent required
condition, not derivable from the spread check; `signal_engine.v` gets this
for free by reading `tob_engine.v`'s already-computed `crossed[slot]` output
directly rather than re-deriving anything from the (potentially misleading)
raw price subtraction.

Not a resolution of a numbered §17 open question — new information the S5
contract-writing process surfaced, same as D11-D14.

---

## Summary — §17 open question disposition

| # | Question | Resolution |
| :-- | :-- | :-- |
| 1 | MAC interface shape | Neither hypothesis — see D1 |
| 2 | MAC RX error signalling | Frame suppression, confirmed; patched to expose it — see D1, D5 |
| 3 | `LINK_MODE` at bring-up | UDP first (reversed from raw-Ethernet-first) — see D3 |
| 4 | Board keys | Four keys, not two; KEY1=kill switch — see D6 |
| 5 | Reject reporting | Counters-only gates S7; `0x11` frames deferred — see D7 |
| 6 | ML normalization | Default kept: runtime registers |
| 7 | Gate `0x09` semantics | Default kept: block-only for v1 |
| 8 | Vivado part string | Resolved 2026-09-01: `xc7a35tfgg484-2` accepted |
| 9 | hls4ml version pin | Owned by the ML collaborator; not decided here |
