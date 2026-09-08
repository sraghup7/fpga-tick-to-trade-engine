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

## D16 — Golden model: position tracking must use the reduced quantity, not the pre-reduction one

**Status: applied**, `sim/golden_model.py`. **Decision:** the position
ledger update on an accepted order now uses `reduced_qty`'s signed value
(`+reduced_qty` for a buy, `-reduced_qty` for a sell), not the unreduced
`order_qty`'s signed value the gate-`0x03` admission check used.

**Why.** Found while designing `risk_engine.v`'s position-tracking
interface for S7. Verified empirically (not just reasoned about) before
writing this entry: with `cfg_ml_action=1` (reduce) and `cfg_ml_reduce_shift=1`,
an accepted order correctly *reported* `quantity=50` (half of
`cfg.order_qty=100`) in its `OrderRecord`, but the internal `position`
ledger incremented by the full, unreduced `100` — the risk engine's own
exposure tracking disagreed with what it had just told the world it traded.
`sim/test_golden_model_handcase.py`'s original 25 messages never exercised
`cfg_ml_action=1` at all (the default config leaves it at `0`, block), so
this went uncaught the same way D14 did — added as a dedicated regression
case (`n1`/`n2`) at the end of that file, using a separately-configured
`GoldenModel` instance.

**What deliberately did NOT change:** gate `0x03`'s own admission check
(`abs(position + signed_qty) > cfg.max_position`) still uses the
*unreduced* `order_qty` — per FR-48, "the ML verdict is advisory to the
risk engine, not a substitute for gates 0x01-0x08," read as: gates 0x01-0x08
evaluate the order as originally sized, and gate 0x09's reduction is an
independent action layered on top, not something that retroactively changes
what the other eight gates saw. Only the *final ledger update*, which
should reflect what actually got sent, needed fixing.

**Consequence for `risk_engine.v`:** its own position-update logic must use
whatever quantity actually gets reported for the order (the ML-reduced one
when that path applies), not the pre-reduction `sig_qty` gate 0x03's own
check reads. See `docs/contracts/risk_engine.md` §2.6 for the exact wording
handed to the implementer.

Not a resolution of a numbered §17 open question — new information the S7
contract-writing process surfaced, same as D12-D15.

---

## D17 — Golden model: gate `0x05` (staleness) was completely unreachable

**Status: applied**, `sim/golden_model.py`. **The most consequential finding
of the S3/S5/S7 contract-writing pass** — this one made a required gate
provably non-functional, not just wrong in an edge case. **Decision:**
`GATE_STALE`'s check now compares `self.current_cycle` against
`prev_update_cycle` — a value captured **before** the triggering message's
own `book.last_update_cycle = self.current_cycle` write — instead of
against `book.last_update_cycle` read *after* that same write.

**Why this was a real, total-unreachability bug, not a corner case.**
Every book-modifying message (`QUOTE`/`CLEAR`) unconditionally set
`book.last_update_cycle = self.current_cycle` near the top of
`process_message`, *before* the signal/risk-gate section runs later in
that same call. Only a book-modifying message can ever reach the risk-gate
section at all (`if not book_modifying: return result`). So by construction,
every single evaluation of `(self.current_cycle - book.last_update_cycle) >
self.cfg.max_age` was comparing `self.current_cycle` against a timestamp
*that message itself had just set to `self.current_cycle` moments earlier* —
always exactly `0`, always `≤ max_age`, for every possible input, forever.
`T18_gate_stale` — a **required** S7 gate test ("silence past `MAX_AGE`,
then fresh update") — could never have passed against the unfixed model,
because the model could never produce a `GATE_STALE` rejection through any
sequence of messages. Verified empirically before writing this entry:
100,000 cycles of silence on a symbol with `max_age=100` still produced
`reject_reason=0` (accepted) under the old code.

**The fix separates "what timestamp gates 0x05 checks against" from "when
the timestamp gets refreshed."** `prev_update_cycle = book.last_update_cycle`
is captured once, before the `msg_type` dispatch (which still refreshes
`book.last_update_cycle` to `self.current_cycle` exactly as before, for
every message type, matching FR-19's "heartbeat refreshes the staleness
timer" language). The later gate-`0x05` check reads `prev_update_cycle`
instead. This makes the test scenario T18 literally describes constructible
for the first time: message A touches a symbol; a long silence follows
(other symbols' traffic advances `current_cycle` past `max_age`); message B
arrives for the silent symbol and is rejected with `GATE_STALE`, evaluated
against A's timestamp; message C, arriving shortly after B, is accepted
again, evaluated against B's (now-fresh) timestamp.
`sim/test_golden_model_handcase.py`'s `n3`-`n6` is exactly this sequence,
verified against the corrected model before being written into the test.

**Consequence for `risk_engine.v`:** its own per-slot `last_update_cycle`
register must be captured/compared **before** being overwritten by the
triggering message's own touch — the same ordering pitfall applies
identically in hardware (a naive "refresh then compare" `always` block
would reproduce this exact bug in RTL). See `docs/contracts/risk_engine.md`
§2.4 for the exact wording and the reasoning behind where the timestamp
update happens relative to the gate evaluation.

Not a resolution of a numbered §17 open question — new information the S7
contract-writing process surfaced, same as D11-D16, but the largest-impact
one so far: an entire gate would have shipped silently non-functional.

---

## D18 — `risk_engine.v`: a rejected order must report its unreduced quantity

**Status: applied**, `rtl/risk_engine.v` (a small, targeted patch to an
already-committed S7 module — see below for why this one, unusually, was
fixed at the RTL directly rather than only in a contract) and
`tb/tb_risk_engine.v` (one new regression assertion). **Decision:**
`order_qty`'s registered update is now `accepted_c ? reduced_qty_c :
sig_qty` — a rejected intent reports the unreduced quantity; only an
*accepted* order reports the ML-reduced one.

**Why.** Found while designing `order_builder.v`'s interface for S8 — that
module is the first thing that would actually consume a rejected order's
`order_qty` field (via the opt-in `0x11` diagnostic frame, FR-44/D7).
Checking what it should read led back to `risk_engine.v`'s own output.
Verified empirically against `sim/golden_model.py` before concluding
anything: with `adverse_risk=1`, `cfg_ml_action=1` (reduce), and a
*different* gate (band, in the test) also firing on the same intent, the
golden model's reject-path `OrderRecord` reports `quantity=100` (the
original, unreduced `order_qty`) — never the reduced value, regardless of
whether ML reduction would otherwise have applied. `docs/contracts/risk_engine.md`
(and the RTL built from it) instead wrote `order_qty <= reduced_qty_c`
unconditionally, on any `sig_valid` cycle, accept or reject — so a rejected
intent under this exact combination would have reported the *reduced*
quantity, disagreeing with the golden model.

**Why this one warranted a direct RTL patch instead of just a contract
note for later:** `order_qty` is a single, already-built, already-committed
output register with no way to route around the bug from a downstream
module without duplicating state that `risk_engine.v` already owns
correctly for the accept case. The fix itself is a single ternary — no
architectural change, low risk to re-verify (the existing testbench still
passed unmodified; a new regression case was added and shown to fail
against the pre-fix RTL before being accepted). Contrast with D12-D17,
which were all `sim/golden_model.py` fixes with no committed RTL to touch;
this is the first finding in the series to reach back into shipped RTL,
and it was worth doing given how easy the fix was and how easy the bug
would have been to miss forever (`cfg_reject_report` defaults to off,
per FR-44/D7, so this field is never observed in the default
configuration — but `order_builder.v`'s testbench, and any future
diagnostic use of gate `0x09` reduce alongside another gate, would have
silently carried the wrong value).

**Practical impact, for context:** low. `cfg_reject_report=0` by design
(FR-44), so this field was never on the wire in the default configuration.
Still worth fixing at the source rather than documenting as a known
limitation, given the fix's cost was essentially zero.

Not a resolution of a numbered §17 open question — new information the S8
contract-writing process surfaced, same as D11-D17, but the first to patch
already-shipped RTL rather than only `sim/golden_model.py`.

---

## D19 — `csr_block.v`: CSR frame wire protocol, counter address map, and STATUS scope

**Status: decided while writing `docs/contracts/csr_block.md` (S9), not yet
implemented.** The master spec (§9) names the CSR frame `msg_type` values
(`0x20` write / `0x21` read-request / `0x22` read-response) and the register
map's addresses for `0x00`-`0x9C`, but leaves four things genuinely
unspecified that the contract has to pin down before any RTL can be written
against it.

**1. CSR frames share `md_parser.v`'s existing byte stream — no new MAC or
`frame_classifier.v` wiring.** Checked directly: nothing in `rtl/eth_mac_if.v`
or the vendored MAC (`rtl/vendor/alinx_mac/`) filters by destination UDP
port anywhere (`cfg_udp_port` / register `0x40` is not consumed by any
existing signal path) — there is no second ingress port to tap even if the
design wanted one. `csr_block.v` therefore taps the *same*
`frame_classifier.v → md_parser.v` byte stream (`in_data`/`in_valid`) as a
second, independent, purely-combinational-adjacent listener, running its own
small byte-serial decode (mirroring `md_parser.v`'s `byte_cnt`/`complete_d`
shape) that recognizes only `0x20`/`0x21` in byte 0 and ignores everything
else. This costs nothing upstream: `md_parser.v` already silently discards
`0x20`/`0x21` today as `err_msg_type` (harmless, pre-existing behavior,
unchanged), and CSR frames are simply zero-effect noise to every
market-data-consuming module the same way market-data frames are
zero-effect noise to `csr_block.v`. CSR write/read-request frames are
defined as the same 16-byte fixed-width envelope as every other frame type
in this system (byte 0 = `msg_type`, big-endian): `addr`(2, offset 2) and
`data`(4, offset 4), rest reserved/zero — see the contract §2.2 for the
exact layout.

**2. `0x22` read-response frames do not go through `eth_mac_if.v` directly
in this contract.** `order_builder.v` already exclusively owns
`tx_payload`/`tx_start`/`tx_busy` (S8). Two masters driving that single TX
interface needs an arbiter that doesn't exist yet and isn't `csr_block.v`'s
job to invent unilaterally — it's an S10 integration concern (`tob_top.v`
wiring). `csr_block.v` instead exposes its own `resp_payload`/`resp_start`/
`resp_busy` outputs, same shape as `order_builder.v`'s TX interface,
independently testable now; a small priority mux combining the two onto the
real `eth_mac_if.v` port is deferred to S10, noted as a follow-up.

**3. Counter addresses (`0xA0`+) are assigned in this decision, spec only
says "Counters — Read-only block, §10."** Assigned in §10's own listed
order, ingress → errors → feed-health → signal → ML → risk → egress →
latency, 4 bytes apart starting at `0xA0` (`cnt_frames_rx`) through `0x134`
(`lat_last`). The 64-bucket histogram (`0x138`-`0x234`) is explicitly
**not** part of this address range's implementation in `csr_block.v` —
that data is owned and computed by `latency_histogram.v` (a separate S9
module, not yet written); `csr_block.v` reserves the range and returns 0
for it until a follow-up wires a real passthrough.

**4. `STATUS` (`0x04`) bits 7:5 ("side-valid map") are a genuine spec gap,
not solved here.** Four watched symbols need 8 bits (bid+ask validity each)
but the register map allocates 3. Rather than silently guess a truncation
scheme, `csr_block.v`'s contract ties bits 7:5 to `0` (reserved) and states
the gap plainly. Bits 0-4 (kill/seq-gap/crossed/stale/ML-adverse) are
defined as **sticky-until-counter-clear** flags (cleared together with the
counters by `CTRL.bit2`), except bit0 (`kill latched`) which mirrors
`risk_engine.v`'s own `kill_latched` level directly (already
latch-until-`CTRL.bit1`-clear by FR-46/47 — re-latching it independently in
`csr_block.v` would let the two disagree).

**Also newly discovered while grounding this contract: `err_fcs`,
`err_ethertype`, `err_ip`, `err_udp_port` have no source signal anywhere in
the current RTL.** Per D1, the vendored MAC's `udp_rx.v` verifies
EtherType/IPv4/UDP framing and the IPv4 checksum before `eth_mac_if.v` ever
asserts anything, but none of those internal checks are currently exposed
as named error pulses. `csr_block.v`'s contract declares input ports for
all four (matching the established `cfg_*`/`err_*` stand-in-port pattern
used throughout this project) but nothing drives them yet; wiring them to
real vendored-MAC signals is future work, same category as `adverse_risk`
standing in for `ml_policy.v` in `risk_engine.v`'s contract.

---

## D20 — `csr_block.v`: `STATUS` bit2 (`crossed`) must be level-sensed, not edge-triggered

**Status: applied**, `rtl/csr_block.v` (a small, targeted patch to the
implementation just delivered for S9, not yet committed) and
`tb/tb_csr_block.v` (one new regression, `C11`). **Decision:** the sticky
`crossed` flag in `STATUS` (bit2) now sets on the plain level `|crossed`
every cycle it's true, not on a registered `crossed_or_d`-based 0→1 edge
detector.

**Why.** Found during independent verification of the delivered
`csr_block.v` (the same discipline as every prior module this series —
recompile, rerun, read the RTL, re-run mutations). The first implementation
latched `status_crossed` only when `(|crossed) & ~crossed_or_d` — i.e. only
on a rising edge. Verified empirically with a standalone testbench: hold
`crossed` continuously asserted (a book that never un-crosses), issue
`CTRL.bit2` (counter clear) while it's still asserted, and `STATUS` bit2
reads back `0` and *stays* `0` for as long as `crossed` never actually
drops to `0` first — because the edge that would re-arm the latch never
occurs. A sticky "has this fault happened since the last clear" flag that
goes permanently dark for an *ongoing* fault right after a routine clear is
the opposite of what it's for.

**Whose bug this is:** the contract's own (`docs/contracts/csr_block.md`
§2.6), not a misreading by the implementer. The original wording — "set on
`(|crossed)` going high" — reads as edge-triggered, and the implementation
followed it faithfully. The mismatch is that `crossed` (`tob_engine.v`) is
a *persisting level*, unlike `seq_gap_pulse`/`gate_stale_fired`/
`ml_adverse_pulse` — the other three sticky triggers — which are genuine
one-shot pulses where edge vs. level is not a meaningful distinction (a
pulse only ever produces one "edge" per event by construction). Writing
the same "goes high" phrasing for all four sticky bits papered over that
one of the four inputs behaves fundamentally differently. Same category of
mistake as the sign-extension error in `risk_engine.md` §2.5 (reusing a
pattern that's correct in one context into a context where the underlying
assumption doesn't hold) — see the general craft-lesson memory note from
that finding.

**The fix simplifies the RTL, not just corrects it:** the level check (`if
(|crossed) status_crossed <= 1'b1;`) needs no `crossed_or_d` register at
all — one line removed, one line changed. Contract §2.6 corrected in place
to state the level-sensed rule explicitly and name the failure mode, so a
future reader (or a future sticky-bit addition) doesn't repeat the mistake.

**Practical impact:** real. Bits 1/3/4 (seq-gap/stale/ML-adverse) were
never affected — their triggers are already one-shot pulses, so
edge-vs-level was never an active distinction for them. Only bit2 was
wrong, and only in the specific scenario of a persisting cross condition
spanning a counter clear — plausible in a genuinely bad feed state, exactly
the situation this diagnostic bit exists to surface.

---

## D21 — `latency_histogram.v`: bucket boundaries, latency source, and two deferred `csr_block.v` wiring gaps

**Status: decided while writing `docs/contracts/latency_histogram.md` (S9's
second and final file), not yet implemented.** Three things the master
spec left open, plus two small gaps in already-committed `csr_block.v`
(`b7e3e9a`) that this contract deliberately does not close.

**1. Latency source: consume `order_builder.v`'s already-computed
`latency_cyc`, don't re-derive it.** `order_builder.v` (S8) already
computes ingress-to-egress `latency_cyc` per transmitted record and embeds
it in the wire frame (`docs/contracts/order_builder.md` §2.3) — the exact
same value the master spec's own README framing calls out ("the host's
capture is simultaneously a latency log," §4.5). `latency_histogram.v`
reads it straight off `ob_tx_start`/`ob_tx_payload[15:0]`, the same two
signals `csr_block.v` already taps for `cnt_orders_tx` (including the same
`msg_type==0x10` exclusion of `0x11` reject-diagnostic frames). No new
`cur_cycle`/ingress-timestamp wiring is needed. Re-deriving the timestamp
independently would duplicate state `order_builder.v` already owns
correctly and risks the two silently disagreeing — same reasoning as D18's
"no clean way to route around state a module already owns."

**2. Bucket boundaries: exact 1-cycle resolution 0-62, bucket 63 as a
saturating ≥63 catch-all — not a linear-shift bucket width.** NFR-2/T25's
entire point is catching a **single-cycle** latency variance ("a second
bucket is a functional bug, not a performance result," §7). A naive
power-of-2 bucket width (e.g. 4 cycles/bucket, the cheap `>>2` shift)
would silently merge a 1-cycle jitter bug into the same bucket and defeat
the requirement it exists to test. With NFR-1's target ≤22 cycles and an
observed nominal engine total of ~10-11 cycles (§12.1), the whole
plausible nominal range fits inside buckets 0-62 at full precision; bucket
63 absorbs any queueing-delayed outlier (an order held behind a busy TX,
`docs/contracts/order_builder.md` §2.4) as an "off-nominal" catch-all
without needing more buckets for a case that's expected to be rare and
isn't what NFR-2 is testing.

**3. `hist_rd_addr`/`hist_rd_data` is a standalone read interface, not
wired into `csr_block.v`'s CSR read mux by this contract.** Same modular
discipline as every S9/S8 contract: `latency_histogram.v` is built and
tested standalone; wiring it to the rest of the pipeline is integration
work. Two specific gaps this leaves in already-committed `csr_block.v`
(`b7e3e9a`), left as explicit deferred follow-ups rather than silently
assumed solved:

- `csr_block.v`'s read mux (`rd32`) currently hard-codes the `0x138`+
  histogram range to return `0` (its `default` case). Making FR-56's "on-
  demand CSR read" of histogram data actually work needs a small patch
  wiring `csr_block.v`'s CSR address decode to this module's
  `hist_rd_addr`/`hist_rd_data`.
- `csr_block.v`'s `counter_clear_pulse` (CTRL bit2) is currently an
  internal `wire`, not exposed as a port. FR-56 groups "counters and
  histogram" together, implying the histogram should clear alongside the
  counters — this module takes a `cfg_counter_clear` input port for that
  purpose, but wiring it from `csr_block.v` needs that pulse exported as a
  new output port there too.

Both are small, well-understood, low-risk patches to already-shipped RTL —
same category as D18's direct `risk_engine.v` patch — deliberately not
done as part of *this* contract to keep it scoped to one module. Flagged
here so they aren't forgotten before S10.

---

## D22 — `tob_top.v`: TX arbitration, two clock domains, and what this integration does *not* attempt yet

**Status: decided while writing `docs/contracts/tob_top.md` (S10), not yet
implemented.** This is the first contract to wire already-committed modules
*together* rather than build a new standalone one, so most of what it has
to pin down is arbitration and clocking, not new datapath logic.

**1. TX arbitration: `order_builder.v` unconditionally wins.**
`order_builder.v` (fast path) and `csr_block.v` (slow path, §3.3 of the
master spec: "forbidden from asserting backpressure onto the fast path")
both need `eth_mac_if.v`'s single `tx_payload`/`tx_start`/`tx_busy`
interface. Neither module is modified — both were already built with an
external-arbiter shape in mind (`docs/contracts/order_builder.md` §2.5's
`~tx_start` self-gate; `docs/contracts/csr_block.md` §2.4's silent-drop
policy for a busy response). The arbiter is a pure mux with no state of
its own:

```verilog
assign eth_tx_payload   = ob_tx_start ? ob_tx_payload : csr_resp_payload;
assign eth_tx_start     = ob_tx_start | (csr_resp_start & ~ob_tx_start);
assign csr_resp_busy_in = eth_tx_busy | ob_tx_start;
```

`order_builder.v`'s own request always passes straight through, never
delayed. `csr_block.v`'s `resp_busy` input is driven by the *shared* path's
busy state OR'd with "`order_builder.v` wants this exact cycle" — so its
own `~resp_busy & ~resp_start` self-gate (already built) correctly holds
off whenever the fast path has priority, with zero new logic inside
`csr_block.v` itself. On the vanishingly rare cycle both request
simultaneously, `order_builder.v` wins and that CSR read is silently
dropped — already an accepted, designed-for outcome per
`docs/contracts/csr_block.md` §2.4 ("CSR traffic is diagnostic, not the
fast path"), not a new failure mode this decision introduces.

**2. Two clock domains, per D2 — this contract makes the split concrete.**
The entire engine (`frame_classifier.v` through `csr_block.v`/
`latency_histogram.v`) runs on the recovered `gmii_rx_clk` (D2). `sys_clk`
(50 MHz board oscillator) is retained *only* for PHY reset sequencing and
`mdio_ctrl.v` — a genuinely separate, slower domain with no signal
exchange with the engine except the reset-release edge (synchronized into
the engine's domain via `rtl/common/sync_2ff.v`, per D2's own "follow-on"
note) and, indirectly, link readiness.

**A concrete bug this decision catches before it ships:** `mdio_ctrl.v`'s
`CLK_HZ` parameter **defaults to `125_000_000`**, but D2 says `mdio_ctrl.v`
runs off `sys_clk` — 50 MHz, not 125 MHz. Instantiating it with the default
would compute the wrong MDC divider (`MDC_PERIOD`), driving the PHY's MDIO
clock at roughly 2.5x the intended rate — silently over IEEE 802.3 clause
22's 2.5 MHz maximum, since `mdio_ctrl.v`'s own math would still produce a
*self-consistent* (just wrong) waveform with no assertion to catch it.
`docs/contracts/tob_top.md` §2.3 requires the instantiation to override
`.CLK_HZ(50_000_000)` explicitly.

**3. This contract does not attempt the ML path, the full T26 soak, or
physical-layer timing closure.** Three deliberate scope boundaries:

- `feature_extractor.v`/`feature_normalizer.v` are **not instantiated** —
  they have no consumer until `ml_classifier_wrap.v`/`ml_policy.v` exist
  (S6, blocked on S4). `adverse_risk` into `risk_engine.v` is a fixed tie-
  off (`1'b0`), same stand-in-input principle `risk_engine.v`'s own
  contract already established, just resolved at the integration level
  now instead of at a testbench boundary.
- **T26's 1,000,000-message soak (`tb/tb_top.v`, master spec §11.3) is not
  this contract's testbench.** §11.3 says that testbench "drives the
  GMII-side interface" — i.e. `mac_top.v`'s own RX/TX boundary
  (`udp_rec_ram_rdata`/`udp_rec_data_valid`/... and
  `ram_wr_data`/`udp_tx_req`/...), the same boundary
  `tb/tb_eth_mac_if_rx.v`/`tb_eth_mac_if_tx.v` already drive standalone.
  That means `tb_top.v` can instantiate the engine chain directly, without
  `tob_top.v`, `mac_top.v`, `util_gmii_to_rgmii.v`, or `mdio_ctrl.v` in the
  loop at all — matching how every other testbench in this project
  exercises its DUT standalone. `docs/contracts/tob_top.md`'s own
  testbench requirement is a smaller connectivity/smoke check (does the
  wiring in *this* contract correctly connect what's already
  independently verified), not a re-run of every module's own behavioral
  coverage.
- RGMII pin constraints, `create_clock` timing, IDELAY/pad-skew validation
  on real hardware, and the PHY's exact minimum reset-pulse-width are S11
  (Hardware) concerns — no board exists to measure any of this against yet
  (`PREREQUISITES.md` has no such number recorded either), so this
  contract specifies a conservative placeholder reset hold count rather
  than inventing an unverified figure.

**A gap this integration closes for free:** `mac_top.v` already carries
D5's patch exposing `mac_rec_error` and `udp_checksum_error` — sources
`docs/contracts/csr_block.md` §1.3 explicitly flagged as *not existing
anywhere in the current RTL* when `csr_block.v` was contracted. Wiring
`mac_rec_error` → `csr_block.v`'s `err_fcs` and `udp_checksum_error` →
`err_ip` closes two of the four stand-in error inputs for real.
`err_ethertype`/`err_udp_port` remain genuine stand-ins — `mac_top.v`
doesn't expose a distinct failure signal for either (a wrong-EtherType or
wrong-port frame is dispatched to neither `arp_rx.v` nor `ip_rx.v`/
`udp_rx.v` and is simply never seen, D1/D3), so there is still nothing to
wire there.

---

## D23 — `signal_engine.v` read `tob_engine.v`'s book bus one message stale; the trigger for the biggest cross-module finding of this project

**Status: found while independently verifying `tob_top.v`'s delivered
implementation (S10), fixed and independently re-verified.** The single
most consequential finding of this session — bigger in impact than D17,
because it's in the core trading decision, not a diagnostic or CSR nuance.
Fix delivered against `docs/contracts/tob_engine_signal_patch.md`,
re-verified directly: recompiled/reran all three required testbenches
(`tb_tob_engine.v`, `tb_signal_engine.v`, the new `tb_signal_tob_chain.v`)
myself, read both diffs (clean — `tob_engine.v`'s seven new ports are pure
`assign`s of already-computed wires; `signal_engine.v`'s change is
contained to the seven `s_*` alias lines, everything downstream
byte-identical), and reproduced the original bug myself as a mutation
(reverted `tob_engine.v`'s `next_*` assigns to source from the *current*
state instead of `nb_*`/`addr_crossed_next`) — the new chain testbench
caught it immediately and specifically at the exact headline case (a bid
QUOTE then an ask QUOTE failing to fire), confirming both the fix and the
new regression's power to catch a regression of this exact bug in the
future. Restored and reconfirmed `PASS` afterward.

**The bug.** `signal_engine.v`'s own header comment states it reads
"the tob_engine.v state buses (POST-update state of the applied slot)"
gated on `book_upd_valid`. It does not. `tob_engine.v`'s `bid_price`/
`ask_price`/`bid_qty`/`ask_qty`/`bid_valid`/`ask_valid` outputs are wired
only to registered state (`assign bid_price = bid_price_r;`), and
`book_upd_valid` is combinational, firing the *same* cycle the triggering
message arrives. In synchronous Verilog, a register written with `<=` on a
clock edge is not visible to another module reading it *on that same
edge* — the new value is only visible starting the next cycle. So
`signal_engine.v` evaluates `buy_ok`/`sell_ok` against the book as it
stood **before** the triggering message's own effect, not after.

**Verified two ways before concluding anything, per this project's own
standing rule:**

1. **Against `sim/golden_model.py`**, the authority this whole project is
   bit-exact-verified against: `process_message` updates `book.bid_price`/
   `book.ask_price`/etc. *first*, then evaluates `buy_ok`/`sell_ok` in the
   same function call, using the just-updated state. The golden model's
   semantics require post-update evaluation; the RTL delivers pre-update.
2. **Empirically, in isolation** — a standalone testbench chaining only
   `tob_engine.v` + `signal_engine.v` (no other module in the loop), fed a
   bid QUOTE then an ask QUOTE that together satisfy every `buy_ok`
   condition (spread 5 ≥ min 2, `bid_qty` 100 > `ask_qty`≪1). `sig_valid`
   never fired from those two messages alone — only a third, redundant
   re-quote triggered it, confirming the one-message lag directly.

**Why neither module's own testbench caught this.** Every module in this
project is tested standalone with hand-driven stimulus
(`docs/contracts/*.md` §3 sections, uniformly). `tb_signal_engine.v` drives
`bid_price`/`ask_price`/`book_upd_valid` as independent stimulus — the
test-writer naturally sets up "the book already looks like X, *then* pulse
`book_upd_valid`," which is exactly the shape that makes the bug invisible
in isolation. Only chaining the two real modules together — which
`tob_top.v` is the first thing in this project to actually do — could
surface it. This is the precise justification for `docs/contracts/tob_top.md`
§3's own connectivity-testing requirement, now doubly confirmed: **wiring
mistakes and cross-module *timing* mistakes are a different bug class from
anything a standalone unit test can find.**

**How `tob_top.v`'s implementer (DeepSeek) actually encountered this and
what they did with it, for the record:** they found the identical
behavior, described it accurately in their own delivery report ("signal_engine
reads the book bus on the book_upd_valid cycle, and tob_engine commits
each QUOTE at the end of that cycle"), and worked around it in
`tb_tob_top.v`'s T1 case by sequencing a bid, an ask, and a redundant
re-quote before expecting a signal. That workaround is accurate
engineering observation, correctly reported — but it papers over a real
defect rather than fixing it, and would very likely make `tb/tb_top.v`'s
eventual T26 byte-for-byte soak against `sim/golden_model.py` fail once
built, since the golden model does not need three messages where the RTL
does. Not a criticism of the implementation work itself — DeepSeek was not
asked to modify already-committed S3/S5 modules as part of a wiring-only
S10 contract, and flagging rather than silently "fixing" an out-of-scope
defect was the right call within that contract's boundaries. The fix
belongs in a dedicated patch contract instead — see
`docs/contracts/tob_engine_signal_patch.md`.

**The fix, in outline (full detail in the patch contract):**
`tob_engine.v` already computes the post-update ("next") state of the
applied slot combinationally, internally, for its own crossed-detection
purposes (`nb_bp`/`nb_bq`/`nb_bv`/`nb_ap`/`nb_aq`/`nb_av`,
`addr_crossed_next`) — it just never exposes them. The fix adds seven new
output ports carrying exactly those already-computed wires, and rewires
`signal_engine.v` to read them directly instead of indexing the registered,
per-symbol flattened bus by `applied_slot`. This is lower-risk and smaller-
blast-radius than the alternative (adding a pipeline stage inside
`signal_engine.v` to wait for the registered state to catch up), which
would change its latency and break the "exactly two registered cycles
from `md_parser`'s `msg_valid` to `risk_engine`'s `order_valid`" invariant
`order_builder.v`'s own `seq_d0`/`seq_d1` pipeline depends on
(`docs/contracts/order_builder.md` §2.2).

**Everything downstream of `signal_engine.v` is unaffected — confirmed,
not assumed.** `risk_engine.v` reads `tob_engine.v`'s `crossed`/`bid_price`/
`ask_price` buses at `sig_slot`, which is `signal_engine.v`'s own
*registered* `applied_slot`, landing at least one full cycle after
`book_upd_valid`. By then the triggering message's register write has
already committed, so `risk_engine.v` sees genuinely post-update state.
The bug is narrowly scoped to whatever reads `tob_engine.v`'s bus
*combinationally, on `book_upd_valid`'s own cycle* — currently only
`signal_engine.v`.

**A second module has the identical latent defect, not yet exercised:**
`feature_extractor.v`'s own header comment makes the exact same false
claim ("post-update state") about the exact same bus, gated the same way
on `book_upd_valid`. It is not wired into anything yet (S6 is blocked on
S4), so this isn't currently observable, but it will reproduce this same
bug the moment S6 wires it in. Flagged here, **not fixed as part of this
patch** (no current consumer, out of scope) — whoever writes S6's
integration contract needs to read this entry first and wire
`feature_extractor.v` to the same new `tob_engine.v` "next" ports this
patch adds, not the stale registered bus.

**Consequence for the not-yet-committed `tob_top.v`:** its current
delivered `rtl/tob_top.v` wires `signal_engine.v`'s *old* port list (the
flattened bus). Once this patch changes that port list, `tob_top.v` needs
a small follow-up edit to its `u_sig` instantiation — and its own T1 test
case should be simplified to drop the re-quote workaround once the fix is
verified, since two messages (not three) should then suffice.

---

## D24 — S6 ML integration: fallback classifier, and three deliberately deferred scope items

`docs/contracts/ml_integration.md` wires the ML branch (`feature_extractor.v`
→ `feature_normalizer.v` → `ml_classifier_wrap.v` → `ml_policy.v`) into
`tob_top.v` for the first time, closing risk gate `0x09` (`adverse_risk`
was tied to `1'b0` since D22). S4 (`model/`, `hls4ml/`) has not started, so
per master spec §15's standing fallback, `ml_classifier_wrap.v` is a
hand-written 8-MAC linear classifier (`z = bias + Σw_i·x_i`, weights/bias
loaded via `$readmemh` from `model/weights.mem`/`bias.mem`) rather than an
hls4ml-generated IP. The weights are an explicit, documented placeholder
(`w_i=1` for all `i`, `b=0`) — not trained, chosen only so every test
vector is hand-computable; `model/model_config.json` records this. When S4
lands, only the two `.mem` files change — `ml_classifier_wrap.v`'s port
list and every other module's wiring stay untouched by design.

Because the classifier is small enough to close timing in one
combinational cycle (vs. the master spec's own budget of 2–3 cycles for a
pipelined hls4ml IP), the signal branch's order intent needs only a
3-cycle alignment delay (`ALIGN_DEPTH`, a `tob_top.v` `localparam`, fed
into the new reusable `rtl/common/delay_line.v`) to reach `risk_engine.v`
on the same cycle `ml_policy.v`'s registered `adverse_risk` reflects the
same triggering event — shallower than the master spec's estimate of
4–5 cycles, purely because this fallback classifier is faster than the
real IP will be. **This is a load-bearing consequence worth its own entry
below (D25) — it silently breaks an invariant `order_builder.v` depends
on.**

Three scope items were deliberately deferred, not silently dropped:

1. **Fail-safe forcing (FR-26/31) covers invalid side / crossed book /
   sequence gap, but not per-event staleness.** `risk_engine.v`'s own gate
   `0x05` already independently blocks any order built from a stale
   message regardless of the ML verdict, so the safety property "no order
   emitted from stale state" already holds. The gap: a stale event's
   (possibly meaningless) `z` can still update the *persisting* hysteresis
   state that carries into the next, fresh event. Fixing this properly
   would mean duplicating `risk_engine.v`'s `pend_prev_cycle`/
   `pend_msg_cycle` per-slot timestamp mechanism inside `ml_policy.v` for
   every book event (today it only runs for events that also produce a
   `signal_engine.v` intent) — real, separate work.
2. **`score_raw`/`risk_level` (FR-33) are computed by `ml_policy.v` but
   left unconnected in `tob_top.v`** — no CSR-readback register or
   diagnostic-frame mechanism exists yet to consume them.
3. **`cfg_ml_window` (CSR `0x5C`) still has no RTL consumer.**
   `feature_extractor.v`'s window depth is the elaboration-time `WINDOW`
   parameter (D13), not a runtime signal — this mismatch between the CSR
   register's existence and its (lack of) effect predates S6 and is not
   introduced or resolved by it.

## D25 — S6's alignment delay breaks `order_builder.v`'s fixed-2-cycle `trigger_seq`/`latency_cyc` assumption

**Found during S6 integration, not fixed — flagged for a dedicated
follow-up.** D23 already named the exact invariant this breaks:
`order_builder.v`'s `seq_d0`/`seq_d1` and `ingress_d0`/`ingress_d1` are an
*unconditional* two-stage shift register (`docs/contracts/
order_builder.md` §2.2) that blindly shifts every cycle, relying entirely
on "the total registered latency from `md_parser`'s `msg_valid` to the
matching `order_valid`/`reject_reason` is exactly two cycles" (its own
header comment) to guarantee `seq_d1`/`ingress_d1` happen to hold the
*triggering* message's sequence number and ingress cycle at the moment
`order_valid` fires — no explicit tagging, just a matched-length delay
line assumption.

D24's `ALIGN_DEPTH=3` cycles added to the signal→risk path (D24) makes
that latency five cycles, not two. `order_builder.v`'s shift register was
not touched (out of scope for `docs/contracts/ml_integration.md`), so
`seq_d1`/`ingress_d1` now hold whatever message arrived **three events
after** the actual trigger, not the trigger itself. Concretely, for every
order accepted since S6 landed: `trigger_seq` in the emitted order frame
attributes the order to the wrong market-data message, and `latency_cyc`
is computed against the wrong ingress timestamp — both wrong by a fixed
but incorrect offset, not merely "off by 3" in a harmless sense.

**Why the full regression, including the 1,000,000-message soak, did not
catch this:** `latency_histogram.v` reads its `lat_value` from
`order_builder.v`'s own (now-wrong) `latency_cyc` field
(`docs/contracts/latency_histogram.md`), and NFR-2's soak-level check only
asserts a *single occupied bucket* — i.e. that the reported latency is
*consistent* across the run, not that it is *correct*. A fixed
systematic misattribution produces one bucket at the wrong value, which
passes that check. No existing testbench asserts `trigger_seq`'s or
`latency_cyc`'s absolute value against the actual triggering message, so
nothing was positioned to catch this.

**Not fixed here** — deliberately out of `docs/contracts/
ml_integration.md`'s scope (`order_builder.v` was explicitly listed as
untouched). The fix belongs in `order_builder.v` itself: either widen the
unconditional shift register to `ALIGN_DEPTH + 2` stages (making
`ALIGN_DEPTH` a shared constant both modules reference, so this can't
silently drift again), or replace the blind shift-register assumption
with something that doesn't depend on a hand-matched constant at all. A
dedicated follow-up contract is needed before this project's latency/
`trigger_seq` claims (§12.1, the "host's order capture doubles as a
latency log" claim in `CLAUDE.md`) can be trusted again.

**Resolved** (`docs/contracts/order_builder_trigger_delay_patch.md`):
`order_builder.v`'s hand-rolled shift register was replaced with an
instance of `rtl/common/delay_line.v` (the same module `ALIGN_DEPTH`
itself uses), its depth exposed as a new `TRIGGER_DELAY` parameter;
`tob_top.v` supplies `2 + ALIGN_DEPTH` from the same `ALIGN_DEPTH`
`localparam` the alignment delay line already defines — one source of
truth, chosen over the shared-constant alternative above because it
also eliminates the duplicate shift-register implementation, not just
the drift risk. Independently verified: `git diff` on `risk_engine.v`/
`signal_engine.v`/`delay_line.v`/`csr_block.v`/`latency_histogram.v`
confirmed empty, `tb_order_builder.v`'s existing coverage passes
unmodified (default `TRIGGER_DELAY=2`), the new `tb_order_builder_delay.v`
passes at the real depth, T6/T7's order frames were hand-decoded and now
show `trigger_seq=4`/`6` (matching their triggering messages) with
`latency_cyc=6`, and a from-scratch mutation (forcing `TRIGGER_DELAY`
back to the old hardcoded `2`) reproduced exactly a 3-cycle
(`ALIGN_DEPTH`-sized) `latency_cyc` discrepancy, confirming the fix's
cycle accounting is exact, not just directionally plausible.

---

## D26 — First real Vivado synthesis attempt (S11 prep): three fixed blockers, one open — `feature_extractor.v` fails timing at 125 MHz

**Context:** starting S11 (hardware bring-up), attempted the first real
`scripts/build.tcl` run against the current, post-S6/D25 `tob_top.v` —
every synthesis-adjacent claim up to this point had only ever been
exercised by Icarus simulation and CI's `iverilog` lint, never real
Vivado synthesis/implementation. `results/build/tob_top.bit` already
existed on disk from **2026-09-01**, but its own `timing_summary.rpt`
showed only 25 timing endpoints and a single `sys_clk` clock — the S0
skeleton (`sys_clk`/`rst_n`/`key_in`/`led` only), built before RGMII/MDIO
ports or any engine RTL existed. Nobody had synthesized the real design
before today.

### Three real blockers found and fixed

1. **`constraints/tob_pins.xdc` only constrained the S0 skeleton's four
   ports.** All 15 RGMII/MDIO/PHY-reset pins `tob_top.v` has had since S2
   were entirely unconstrained. Fixed using `docs/refs/AX7035B_pinout_notes.md`'s
   pin table (independently confirmed against both the real
   `AX7035B_UG.pdf` manual and the schematic) cross-checked pin-for-pin
   against ALINX's own working reference design's XDC
   (`docs/refs/AX7035/SRC/21_ethernet_test/.../top.xdc` — same board, same
   JL2121(D) PHY). `constraints/tob_timing.xdc` was missing the RGMII RX
   clock definition (`rx_clk`, 125 MHz on `rgmii_rxc`) entirely — added,
   matching that same reference design's own `create_clock`. No RGMII
   input/output delay budget is set (deliberately — see that reference
   design's own equally minimal treatment, and `AX7035B_pinout_notes.md`'s
   own "still open" note that the JL2121(D)'s real AC timing has never
   been re-derived from Micrel-era KSZ9031RNX assumptions per D9).
2. **`scripts/build.tcl` never globbed `rtl/vendor/alinx_mac/`.** Its
   `add_files` glob only ever covered `rtl/*.v rtl/common/*.v` — the
   vendor MAC/RGMII adapter `tob_top.v` has instantiated since S2 was
   never part of any synthesis attempt. Fixed by extending the glob.
3. **D8's already-flagged IP regeneration gap** (`rtl/vendor/alinx_mac/`
   depends on four Xilinx `fifo_generator`/`blk_mem_gen` IP cores —
   `udp_tx_data_fifo`, `udp_checksum_fifo`, `udp_rx_ram_8_2048`,
   `icmp_rx_ram_8_256` — "tracked as an S2 checklist item," never actually
   done). Fixed: copied the four `.xci` configs from ALINX's own working
   reference design into `rtl/vendor/alinx_mac/ip/<name>/<name>.xci`
   (2018-era XCI schema), `upgrade_ip` brought them to this Vivado
   install's `fifo_generator`/`blk_mem_gen` versions cleanly. These
   default to out-of-context (per-IP) synthesis, which needs a separate
   `write_checkpoint`/`read_checkpoint -cell` merge step; simpler for a
   design this size to set `GENERATE_SYNTH_CHECKPOINT false` on each
   `.xci` so `synth_design` resolves them inline as part of the top-level
   run instead ("Global Synthesis," Vivado's other supported IP flow).
   **Verified, not assumed:** `synth_design` completed with zero
   blackboxes and zero inferred latches (`get_cells -hierarchical -filter
   {IS_BLACKBOX == 1}` / `{IS_LATCH == 1}`, both empty) — the design
   genuinely elaborates and synthesizes end to end for the first time.
   `icmp_rx_ram_8_256` is instantiated with an 11-bit address by
   `icmp_reply.v` despite its `_256`-implying-8-bit name (already noted in
   `tb/sim_models/xilinx_ip_sim_models.v`'s own header) — Vivado only
   warns (`[Synth 8-689] width (11) of port connection 'addra' does not
   match port width (8)`) and truncates/zero-extends rather than erroring;
   worth a closer look before trusting ICMP reply behavior on real
   traffic, not chased further here.

### One real blocker found, not fixed: `feature_extractor.v` fails setup timing

Post-placement timing: **WNS = −9.127 ns** against the 8 ns (125 MHz)
`rx_clk` period — not a rounding-error violation, a real one. The worst
path: `u_csr/cfg_symbol_en_reg[0]/C` → `u_feat/feat_f7_volatility_reg[*]/D`,
36 logic levels, 8.146 ns of pure logic delay before routing is even
added. Same shape across the ten worst paths (all landing on
`feat_f7_volatility_reg[*]`), and a smaller **hold** violation
(`WHS = −0.002 ns`) inside `mdio_ctrl.v`, not investigated yet given the
setup violation dominates.

**Root cause, read from the path, not guessed:** `cfg_symbol_en` feeds
`symbol_filter.v`'s slot selection → `applied_slot`/`sidx` →
`feature_extractor.v`'s per-slot window array indexing → the F5/F7
window's fully-recomputed-every-cycle adder tree (`f7acc`, a 16-term
sum over `WINDOW`, plus the F5 popcount, both combinational in one
`always @(*)` block, per `feature_extractor.v`'s own header). The slot-
select mux and the window sum apparently share/chain LUTs in Vivado's
synthesis, producing a single long combinational cone from a CSR config
register through to F7's output register.

**This was a predicted risk, not a surprise:** master spec §16's risk
table already named "feature adder tree" as a known timing-closure
suspect. It has now materialized for real, confirming that risk entry
was well-founded, not paranoia.

**Not fixed here — needs its own contract, not a quick patch.**
`feature_extractor.v`'s own header explicitly documents the full-recompute
design as deliberate (D13's "never maintained as an incremental
add-newest/subtract-oldest sum" pitfall) — reverting to incremental
accumulation to shorten the combinational path would reintroduce exactly
the correctness bug D13 avoided. The real fix is pipelining (splitting
the F5/F7 computation across two registered cycles, or restructuring the
16-term sum into an explicit balanced adder tree rather than relying on
synthesis inference) — a genuine RTL redesign requiring re-verification
against `sim/feature_golden.py`'s bit-exact semantics and the existing
`tb_feature_extractor.v`/`tb_feature_tob_chain.v`/`tb_ml_chain.v`
regressions, not a same-day fix.

**Consequence for S11:** hardware bring-up cannot proceed on a bitstream
that fails setup timing this badly — `scripts/build.tcl`'s own WNS gate
already refuses to write one (`route_design` was not even attempted here;
no point routing a design already known to fail its own gate). This
blocks every physical S11 step until resolved.

### What's committed vs. not

`constraints/tob_pins.xdc`, `constraints/tob_timing.xdc`,
`scripts/build.tcl`, and the four new `rtl/vendor/alinx_mac/ip/*/*.xci`
files are committed — genuine, independently-verified progress (design
elaborates, synthesizes, places with zero blackboxes/latches). No RTL
fix for the timing violation is included; `results/build/` stays
gitignored as before (no fresh bitstream was produced or committed).

---

## D27 — D26's first timing fix attempt failed real Vivado verification; root cause was misdiagnosed

**Status: applied (v1 discarded via `git stash`, never committed; v2
contract written)**. D26's `feature_extractor_timing_patch.md` (v1) split
the F5/F7 window's up-to-32-term adder tree into two half-window partial
sums, registered one cycle apart, on the theory that the adder tree's width
was the timing-critical resource. It passed every `iverilog` testbench and
`sim/feature_golden.py`/`sim/test_ml_golden_handcase.py` bit-exactly —
correctness was never in question. Independent post-route Vivado
verification (this session, same `scripts/build.tcl` flow as D26) measured
**WNS = -8.277 ns**, barely improved from D26's pre-fix baseline of
-9.127 ns, with the worst path still 36 logic levels, now ending at
`s1_f7acc_lo_reg` instead of `f7acc_reg`.

**Root cause, found by reading the actual routed `report_timing` path, not
re-guessed:** the adder-tree width was never the dominant cost. The
dominant cost is computing *this event's own* F1 (mid-price delta) and its
absolute value — two chained 33-bit additions (`midsum`, `pmsum`) followed
by a saturating subtraction and an abs — entirely unregistered, in the same
cycle the result is immediately folded into the window sum as entry `j==0`.
v1's split only shortened the *historical* window's adder-tree depth by one
level; it left this upstream chain, and its same-cycle fold-in, completely
untouched. Splitting a wide sum in half does nothing for a bottleneck that
sits upstream of the sum entirely.

**v2** (`docs/contracts/feature_extractor_timing_patch.md`, rewritten
in place — v1's text is not preserved separately, since it was never
committed) redesigns around the actual bottleneck instead: F1's two 33-bit
adds are registered before the saturating subtract/abs runs (splitting that
single deep chain across two cycles instead of one), **and** F5/F7 switch
from full-window recompute to an incremental add-newest/subtract-oldest
accumulator — reconsidering D13's own rejection of that scheme now that the
actual constraint (never store or feed back a *saturated* value; saturate
exactly once, at the output register) is stated as an explicit rule rather
than avoided altogether. `feat_valid` moves from `book_upd_valid` +2 (v1) to
+3, bumping `tob_top.v`'s `ALIGN_DEPTH` from 4 to 5.

**Why this belongs in the record, not just a superseded contract file:** a
plausible-sounding timing fix that compiles and passes every simulation can
still fail on real hardware, because Icarus has no notion of routed delay —
only Vivado's actual `report_timing` on the placed-and-routed netlist proves
a fix works. This project's contract-writing process (D26 itself, D8, D25)
already leans on "verify independently, don't trust the report" for
*functional* correctness; this is the same discipline applied to *timing*
closure specifically, and it caught a real, non-obvious miss (the true
critical path ran through logic the original contract never looked at).

**Not yet resolved:** v2 is written and handed off; whether it actually
closes timing is unverified as of this entry (post-route WNS ≥ 0 is my job,
via Vivado MCP, once its `iverilog` regression comes back).

---

## D28 — `risk_engine.v`'s gates 0x04/0x05/0x07 misaligned by `ALIGN_DEPTH`; found via external audit, independently confirmed

**Status: found, confirmed by reading the actual RTL wiring; fix contract
written (`docs/contracts/risk_engine_align_fix.md`), implemented and
verified 2026-09-05** (see the contract's S5 acceptance: `risk_engine.v`
snapshot mechanism + `tb/tb_risk_engine.v` rework with the poison-message
regression, `tb_tob_top.v` alignment-drift guard, full `make sim` regression
green; the tb runs at `TB_ALIGN_DEPTH=5` by default and an extra
`-DTB_ALIGN_DEPTH=3` pass confirms the committed depth — depths 3/4/5/6 all
pass). An external audit (a separate Claude Opus session, pasted in by the user)
raised this along with a dozen other claims. Per this project's own
standing rule — verify independently, never accept a report (including one
from another AI session) at face value — the two highest-severity claims
were checked directly against the RTL before acting on either.

**The bug, confirmed:** `risk_engine.v`'s own header comment (D17) states
"tob_engine's `msg_applied` for a triggering message arrives one cycle
before signal_engine's matching `sig_valid`... the one-cycle pipeline
alignment is automatic by construction." That was true through S7/S9. Once
S6 wired the ML branch's alignment delay in (`docs/contracts/
ml_integration.md`), `u_risk`'s `.sig_valid` port was retargeted to
`sig_valid_aligned` — delayed `ALIGN_DEPTH` cycles — but `.msg_applied`,
`.applied_slot`, `.bid_price`, `.ask_price`, `.crossed` stayed wired to the
raw, real-time signals ([tob_top.v:616-659](rtl/tob_top.v:616)). Nobody
re-derived D17's invariant when that rewiring happened.

Concretely: `pend_prev_cycle`/`pend_msg_cycle` ([risk_engine.v:145-146,
239-243](rtl/risk_engine.v:145)) are a single, non-per-slot register pair,
overwritten on *every* `msg_applied`. They are captured correctly (D17's
mechanism is fine) exactly one cycle after the triggering message, which is
also exactly when the *raw* `sig_valid` fires (confirmed by reading
`signal_engine.v:148-178` — `sig_valid <= 1'b1` one cycle after
`book_upd_valid`, unconditionally). But gate 0x05 doesn't read them until
`sig_valid_aligned` arrives, `ALIGN_DEPTH` cycles later — by which time one
or more intervening messages (any slot, any type) have overwritten both
registers. The same architecture problem hits gate 0x04 (band: reads
`bid_price[sig_slot]`/`ask_price[sig_slot]` in real time, not as of the
triggering message) and gate 0x07 (crossed: same). Gates 0x01/02/03/06/08/09
are unaffected — they only ever read the already-correctly-aligned
`sig_slot`/`sig_side`/`sig_price`/`sig_qty` bus and live config/state that's
meant to be evaluated in real time.

**Severity:** real, live, in already-committed, already S10-integrated RTL
— not hypothetical, and not something the current test suite catches
(`tb_risk_engine.v` tests the module standalone, at a fixed short latency
that never exercises `ALIGN_DEPTH`; `tb_tob_top.v` doesn't currently drive
back-to-back same-slot traffic dense enough to expose it either). At
`NFR-4`'s 16-cycle nominal message spacing it happens not to bite in
practice — `ALIGN_DEPTH` (4, soon 5) is comfortably inside one message
interval — but `NFR-5` explicitly claims "internal pipeline accepts one
message per cycle," which is incompatible with this gate's actual behavior
under dense traffic. The gap was silent because nothing records the real
constraint the design relies on.

**The audit's other headline claim (latch count) was also confirmed, but
its own diagnosis was wrong** — see the correction in this same entry's
sibling investigation: the 32 `LDCE` cells D26 missed (a filter that
silently fails open, `IS_LATCH == 1` vs. the correct
`PRIMITIVE_SUBGROUP == LATCH`) are not benign vendor IP as guessed; they are
`u_risk/token_bucket_reg[*]`, i.e. inside hand-written `risk_engine.v` — a
genuine `NFR-10` violation with a root cause not yet identified (the
`token_bucket`/`refill_ctr` always-block reads as ordinary complete
synchronous logic; why Vivado chose `LDCE` there is a separate open
question, not addressed by this entry or `risk_engine_align_fix.md`).

**Fix approach** (`docs/contracts/risk_engine_align_fix.md`): rather than
widening `tob_top.v`'s existing `u_align` delay line (which would blur
signal-branch and risk-gate concerns together), `risk_engine.v` gains its
own internal `delay_line` instance, keyed on the module's *raw*
(pre-alignment) `sig_valid`/`sig_slot` — both already exist as top-level
wires in `tob_top.v` for `u_csr`'s use, so no new wiring elsewhere is
needed. The internal delay line carries a snapshot of
`bid_price[sig_slot]`/`ask_price[sig_slot]`/`crossed[sig_slot]`/
`pend_prev_cycle`/`pend_msg_cycle` taken at the raw `sig_valid`'s own cycle
(exactly when D17's mechanism guarantees they're correct for that specific
message) forward by the same `ALIGN_DEPTH`, so the values arrive already
correctly time-referenced when the aligned `sig_valid` does. `cfg_max_age`/
`cfg_price_band` stay live (evaluated at the gate's actual cycle, not
snapshotted) — only the *data*, not the *configuration*, needed a time fix.

**`ml_policy.v` has the identical bug class** (`bid_valid`/`ask_valid`/
`crossed` read in real time at `ml_slot`, its own header comment repeating
the same now-false "safe per D23" reasoning) but is explicitly out of scope
for `risk_engine_align_fix.md` — flagged here so it isn't lost, needs its
own contract with its own capture point (the ML branch's internal pipeline
stage where `ml_slot`'s triggering event was last known-valid), not
addressed by this fix.

**Resolved 2026-09-05:** fix implemented per the contract and verified --
`risk_engine.v` now snapshots the book/timestamp state on the raw
`sig_valid` cycle and carries it through its own `delay_line`; the D28
poison-message regression cases (P1-P4) in `tb/tb_risk_engine.v` prove gates
0x04/0x05/0x07 evaluate the triggering message's own state under interleaved
traffic. `ml_policy.v`'s identical bug class and the
`u_risk/token_bucket_reg[*]` latch inference remain open (see the entries
above).

---

## D29 — `scripts/build.tcl` had three real verification gaps; fixed directly (not a contract — build/tooling, not RTL)

**Status: applied**, `scripts/build.tcl`, `constraints/tob_timing.xdc`. Same
external audit as D28 raised these; all three independently confirmed
before fixing, not taken on the audit's word alone.

1. **The latch-detection query silently failed open.**
   `get_cells -hierarchical -filter {IS_LATCH == 1}` — the exact query D26
   used to record "zero inferred latches — verified" — returns an empty
   list even when real latches exist, because `IS_LATCH` isn't set on
   `LDCE` cells the way synthesis actually classifies them. Confirmed
   directly in a live Vivado session against the real (pre-D27) routed
   netlist: `IS_LATCH == 1` → 0 cells; `PRIMITIVE_SUBGROUP == LATCH` → 32
   cells, all `u_risk/token_bucket_reg[*]_LDC` (D28's other finding — real
   hand-written-RTL latches, not benign vendor IP as the audit itself first
   guessed). `build.tcl` now uses `PRIMITIVE_SUBGROUP == LATCH` and prints
   every offending cell's hierarchical path on failure, not just a count.

2. **Reports were written after the WNS gate, not before.** Every real run
   since 2026-09-01 has failed that gate and exited before reaching
   `report_utilization`/`report_timing_summary` — confirmed by file
   timestamp: `results/build/utilization.rpt`, `timing_summary.rpt`, and
   `tob_top.bit` were still frozen at 2026-09-01 19:38 (the original S0
   skeleton build) as of this entry, silently describing a design many
   commits out of date, sitting exactly where anyone would look for current
   results. Reports now run unconditionally right after
   `route_design`/`synth_design`, before any gate check that might `exit`.

3. **No hold-timing gate**, despite D26 recording an unexplained
   `WHS = -0.002 ns` in `mdio_ctrl.v`. Added a WHS check alongside the
   existing WNS one (`get_timing_paths ... -hold`, confirmed working syntax
   against a real routed design before landing). Root-caused the likely
   source of that violation at the same time: `sys_clk` and `rx_clk` had no
   `set_clock_groups` exception, so Vivado was timing every path between
   them as if synchronous. The two real crossings (`kill_sw_n`, the async
   reset) already go through proper `sync_2ff.v` synchronizers;
   `mdio_done_latched`'s only fan-out is an LED output pin, which has no
   setup/hold requirement. Added
   `set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks rx_clk]`
   to `constraints/tob_timing.xdc` — this declares the two domains properly
   handled by design, it does not paper over an unsynchronized crossing
   (there isn't one).

**Not a contract** because it's build-script/constraint tooling, not RTL —
no `iverilog`/testbench surface applies. Verification is a real
`vivado -mode batch -source scripts/build.tcl` run (the header's own
documented invocation — sourcing it inside a persistent interactive Tcl
session instead kills the session outright, since `exit` terminates the
whole Vivado process by design, exactly as it should for the real one-shot
usage).

**Verified with a real run, same day:** `vivado -mode batch -source
scripts/build.tcl` against the current design correctly found all 32 real
latches with the corrected filter, printed every one's full hierarchical
path (`u_risk/token_bucket_reg[0..31]_LDC` — confirming D28's finding
exactly), and failed cleanly with `exit 1` before place/route — the
intended behavior. `results/build/utilization_synth.rpt` was confirmed
freshly written before the gate ran, and `results/build/tob_timing.xdc`'s
new `set_clock_groups` line parsed with no error ("Applying XDC Timing
Constraints" completed clean in the log). The build correctly still fails
overall, as it must until D28's actual latch root cause is fixed — this
entry's job was only to make that failure loud and correctly-diagnosed
instead of silently missed.

**Still open, deliberately not touched here:** the `token_bucket_reg`
latch's actual root cause (D28) — this entry only makes it possible to
*detect* that violation reliably; the design still won't pass its own gate
until that's fixed. `results/build/tob_top.bit` remains stale until a real
passing build runs.

---

## D30 — `sim/golden_model.py` had two real ML-counter bugs; fixed directly (Python bookkeeping, not RTL)

**Status: applied**, `sim/golden_model.py`. Same external audit as D28/D29;
both claims read against the actual code and the master spec's own §10
text, then fixed and independently re-verified with a from-scratch script
(not just re-running the existing hand-case, which doesn't exercise either
path) before considering this closed.

1. **`cnt_rej_ml` was double-incremented on every ML block.** The
   gate-pulse loop (`for g in gates_fired: self.counters.inc(GATE_NAME[g])`)
   already increments `cnt_rej_ml` once whenever `GATE_ML` fired, since
   `GATE_NAME[GATE_ML] == "cnt_rej_ml"`. A second, redundant
   `self.counters.inc("cnt_rej_ml") if GATE_ML in gates_fired else None`
   sat immediately after it — its guard was never actually selective
   (`GATE_ML in gates_fired` already implies `adverse_risk` is true), so it
   fired every single time the loop above already counted the same event.
   Removed. Verified with a fresh script (not the existing hand-case, which
   never exercises this path): a block-mode ML rejection now reads
   `cnt_rej_ml == 1`, not 2.

2. **`cnt_ml_events`/`cnt_ml_adverse`/`cnt_ml_benign` only counted when the
   deterministic signal engine also fired.** The master spec's own §10
   defines `cnt_ml_events` as "valid feature vectors processed" — per
   S3.1's architecture the ML branch is a separate, parallel pipeline off
   `book_upd_valid`, entirely independent of whether `signal_engine.v`'s
   spread/imbalance rule also produced an intent. The Python placed this
   bookkeeping block *after* the `if buy_ok: ... elif sell_ok: ... else:
   return result` early-return, so a book-modifying event with a tight
   spread (or any other reason neither `buy_ok` nor `sell_ok` fired) never
   incremented any ML counter at all, even though `ml_policy.v` and every
   feature-extraction stage in the real RTL run unconditionally on that
   same event. Moved the block to right after the `book_modifying` check,
   before signal-engine evaluation. Verified with a fresh script: a
   tight-spread QUOTE pair (`min_spread` set unreachably high) now correctly
   reads `cnt_ml_events == 2` with `signal_fired is None` for both, where it
   previously read `cnt_ml_events == 0`.

**Why these are Python-only, not RTL fixes:** `ml_policy.v` and
`risk_engine.v` were already doing the right thing (RTL increments
`cnt_ml_events`/etc. via `csr_block.v` on every `ml_event_valid`/
`ml_adverse_pulse`/`ml_benign_pulse`, unconditionally, and fires
`gate_ml_fired` — hence `cnt_rej_ml` — exactly once per qualifying event via
a single registered pulse). The golden model, not the hardware, had drifted
from the spec's own stated definitions. Neither bug was reachable by the
existing `sim/test_golden_model_handcase.py` (it doesn't drive a
tight-spread book with `adverse_risk=True`, nor check `cnt_rej_ml` at all)
— both were latent until this audit, and both would have produced a wrong
answer the moment a full-system (`tb/tb_top.v`, not yet written) comparison
checked these specific counters against RTL.

**Same audit also raised a third, related ML-counter claim (reduce-mode
`cnt_rej_ml`)** — the spec's own §10 line literally reads "gate `0x09`
blocked/**reduced**," but both the RTL (`gate_ml_fired_c = adverse_risk &
~cfg_ml_action`) and this file only ever count block-mode ML actions,
never reduce-mode ones. RTL and the (now-fixed) golden model agree with
each other here, so this isn't a bug in either implementation — it's the
spec's own parenthetical that's imprecise, and reads more like a documentation
gloss than a considered requirement (FR-48 already treats gate 0x09's
reduction as "the ML reduction is gate 0x09's own action," distinct from
the other gates' outright rejection, and a reduced order still gets
`order_valid=1` — it was never actually rejected, just resized, so folding
it into a "rejection" counter would be a stretch even taken literally).
**Deliberately not resolved here** — this is a normative-text question
about what the requirement should say, not an implementation bug to
silently patch; flagging for an explicit decision rather than editing the
master spec's own counter semantics unprompted.

---

## D31 — `sim/ml_golden.py`'s docstring wrongly credited the RTL as its derivation source; re-derived from spec, no behavior change

**Status: applied**, `sim/ml_golden.py` (docstring only). Same external
audit; this specific claim was checked by actually doing the independent
re-derivation it demanded, not just editing the comment to say one had
happened.

The file's own header said two contradictory things: "Written from the
spec, not the RTL, per S11.1" and, twenty lines later, "Hysteresis +
fail-safe forcing transcribed directly from ml_policy.v's always block."
The second sentence describes what actually happened, and is exactly the
process CLAUDE.md's golden-model rule exists to prevent: *"a model derived
from the RTL only confirms the RTL matches itself."* If `ml_policy.v` had a
latent bug in its hysteresis or fail-safe logic, a model transcribed from
that same logic would reproduce the bug and `test_ml_golden_handcase.py`
would report a false PASS — precisely the failure mode that let D28's
`risk_engine.v` misalignment and D30's counter bugs sit undetected.

**Re-derivation, done properly this time:** read `fpga_tick_to_trade_
master_spec.md` §5.4 (model spec), §9 (`ML_SCORE_OFFSET`/`ML_SCORE_SHIFT`
register definitions), and FR-26/27/28/29/31/33 directly — without opening
`ml_policy.v`/`ml_classifier_wrap.v` again — then compared the result
against the existing code. They matched exactly: `z = b + Σw_i·x_i` (§5.4,
FR-27), `risk_level = saturate((z+offset)>>shift)` (§9's literal register
description, §5.4's table row), hysteresis `z>=T_high` sets /
`z<=T_low` clears / else holds (FR-28/29), fail-safe forcing on invalid
side / crossed / sequence gap specifically — and *only* those three
conditions; FR-26 does not list staleness, matching `ml_policy.v`'s own
(separately correct) header note that staleness forcing is deliberately
not duplicated here since `risk_engine.v`'s gate 0x05 already covers it.

**No behavior changed.** The existing arithmetic was already spec-correct
— confirmed independently here, not merely re-asserted — so this is a
provenance/documentation fix (the docstring now cites spec clauses, not
`ml_policy.v`'s own block, as the source), verified by re-running
`sim/test_ml_golden_handcase.py` (unchanged, passes). The value of this
entry is process, not a bug fix: an independent re-derivation was actually
performed and happened to confirm the existing numbers, which is a
meaningfully different (and stronger) claim than "the docstring now says
the right thing."

---

## D32 — NFR-7 (resource budget) is badly violated; recorded, not fixed

**Status: recorded, not resolved.** Same external audit; NFR-7 says
"Engine logic **excluding the ML classifier** consumes ≤15% LUTs (≈3,100 of
20,800), ≤10% FFs... and 0 DSP." §12.2 (the results table this belongs in)
is empty — nothing had recorded that the design doesn't come close to
meeting this, which the audit correctly flagged as a real gap independent
of any RTL bug.

**Measured (synthesis-stage, `results/build/utilization_synth.rpt`, the
2026-09-05 `build.tcl` run confirmed in D29 — post-place-and-route numbers
don't exist yet since the design still fails D29's own latch gate before
reaching `place_design`, and Vivado's own utilization report warns LUT
counts are "typically lower" after full implementation, so these will
shift, likely downward, once a build gets further):**

- Slice LUTs: 12,107 / 20,800 = **58.2%** (budget: ≤15%, ≈3,100)
- Slice Registers: 12,377 / 41,600 = **29.75%** (budget: ≤10%)

Roughly a 4x and 3x overshoot respectively. **Root cause, not chased down
cell-by-cell here, but reasonably attributable in large part to
`rtl/vendor/alinx_mac/`** (D1's vendored MAC datapath: full MAC/ARP/IP/UDP/
ICMP stack, four Xilinx FIFO/BRAM IP cores) — NFR-7's ≤15%/≤10% figures
read like they were sized for a hand-rolled minimal engine, and D1 (vendor
the MAC rather than write one) was a real, deliberate, already-justified
tradeoff (multi-week from-scratch RGMII MAC risk vs. a working, board-
matched one) made **after** NFR-7's number was likely fixed — nobody
reconciled the two. Whether NFR-7's budget should explicitly exclude the
vendored MAC (matching its ML-classifier carve-out precedent) or whether
the number itself needs revising is a spec-text question, not an
implementation bug — **deliberately not resolved here**, same reasoning as
D30's reduce-mode `cnt_rej_ml` finding: this is normative text that needs an
explicit decision, not something to silently edit.

**Not touched:** no RTL change, no §12.2 table filled in (there's no
post-implementation build to report yet — D28/D29's fixes have to land and
actually pass the WNS/latch gates first). This entry exists so the gap is
recorded before it's forgotten, per the same audit that already caught two
things (D26's latch check, D30's counters) that went unrecorded the same
way.

---

## D33 — `feature_extractor_timing_patch.md` v2 implemented and verified: the F1/F5/F7 timing bottleneck is fully closed

**Status: applied and independently verified**, `rtl/feature_extractor.v`,
`rtl/tob_top.v` (`ALIGN_DEPTH` 3→5), `tb/tb_feature_extractor.v` (new Block
F), `tb/tb_feature_tob_chain.v`, `tb/tb_ml_chain.v`. GLM was assigned this
contract but made no progress (the RTL and testbench files were still at
their pre-contract baseline timestamps); implemented directly instead of
waiting further, following the design already written in
`docs/contracts/feature_extractor_timing_patch.md`.

**Implementation:** the three-stage pipeline exactly as specified — stage 0
computes the two wide 33-bit sums plus every cheap feature, stage 1 computes
F1 from the now-registered sums, stage 2 does the incremental F5/F7
accumulate (40-bit accumulator, sized for `WINDOW`'s full legal range per
D27's own correction, not today's `WINDOW=16`). `feat_valid` now pulses 3
cycles after `book_upd_valid`.

**Verification, each independently confirmed, not merely re-run:**

- Full `iverilog` regression (`bash scripts/run_sim.sh`, including the
  1,000,000-message soak) passes with this change plus D28's independent
  `risk_engine.v` fix landed simultaneously.
- **New dynamic D13-safety regression** (`tb/tb_feature_extractor.v` Block
  F): drives F7 into genuine 32-bit saturation (three simultaneous
  `|F1|`-saturated entries in a `WINDOW=4` instance) and through every one
  aging back out, checked at each step against `sim/feature_golden.py`'s
  independent from-scratch-recompute oracle (immune to this bug class by
  construction, not hand-derived). The critical checkpoint — the last huge
  entry aging out — recovers to an exact unsaturated value (`0x80000000`),
  not a corrupted one. No existing test before this one drove real
  saturation; Block C's rollover test used numbers nowhere near 2^32.
- **Post-route Vivado synthesis (the actual point of this whole exercise):
  the `feature_extractor.v` critical path is completely gone** — not merely
  improved, absent from the top-10 violated paths entirely. Overall design
  WNS improved from **-8.277 ns (v1, D27) to -2.282 ns** — the design still
  doesn't close timing overall, but for a reason entirely unrelated to this
  contract's scope; see D34.

**Confirmed via direct RTL reading, not assumed:** `prev_bp/prev_bq/prev_ap/
prev_aq/seen_first/last_trade_dir` were not moved into the new pipeline
(still keyed off stage 0's `book`/`clev`/`sidx`/`sbp`/`sbq`/`sap`/`saq`,
updating one cycle after `msg_applied` exactly as before); the D13-safety
rule holds (the accumulator and window array only ever store or subtract the
raw, unsaturated per-event magnitude — `p2_push_abs`, never
`feat_f7_volatility` — confirmed both by reading the RTL and by Block F's
dynamic recovery check).

---

## D34 — Combining the D26/D27 and D28 fixes surfaces a NEW timing bottleneck, entirely inside `risk_engine.v`, that neither fix's own verification could have caught alone

**Status: found, not yet fixed (as of this entry's original writeup);
fixed and verified 2026-09-05 via `docs/contracts/risk_engine_gate_pipeline_fix
.md` (S5 acceptance green: two-stage gate pipeline in `risk_engine.v`,
`TRIGGER_DELAY` ripple to `3+ALIGN_DEPTH` in `tob_top.v`, new same-slot
spacing regression T300/T301 in `tb_risk_engine.v`, full `make sim`
regression green).** Once D33's `feature_extractor.v` fix
removed the previous critical path, and D28's `risk_engine.v` fix landed
alongside it, a real post-route synthesis of the COMBINED design surfaces a
different worst path, entirely new: **`u_risk/u_gate_align/data_pipe_reg[4]
[98]/C -> u_risk/position_r_reg[*]/CE`, WNS = -2.282 ns, 21 logic levels**.

**Root cause, traced from the actual routed path, not guessed:** D28's
internal `u_gate_align` delay line (129 bits wide, `ALIGN_DEPTH=5` deep)
snapshots `bid_price`/`ask_price`/`crossed`/the staleness timestamps and
carries them forward so they land correctly time-referenced when the
aligned `sig_valid` arrives — that part is correct and was independently
verified (D28's own mutation test still passes). But the delay line's LAST
register stage feeds DIRECTLY, with no register in between, into
`risk_engine.v`'s full nine-gate reject-reason priority mux and the gate
0x04 band-diff arithmetic — the same combinational cone that used to be fed
by cheap top-level ports (`bid_price`/`ask_price` direct wires) is now fed
by a register bank several dozen routing cells away from a much larger,
denser piece of logic (a 129-bit-wide delay line), and that extra
routing/fan-out distance is enough to push what was previously comfortably
inside budget over it.

**This was invisible to either contract's own verification, structurally,
not by oversight:** `feature_extractor_timing_patch.md`'s acceptance
criteria only covered `feature_extractor.v`'s own path (correctly — that
contract has no way to know what `risk_engine.v` will look like after
placement). `risk_engine_align_fix.md`'s acceptance criteria (correctly)
scoped Vivado verification to confirming the fix's *correctness*
(gate_snap_out_valid/sig_valid coincidence, the poison-message regression)
without a route-level timing check, since a logic-correctness contract has
no reason to assume `ALIGN_DEPTH` will simultaneously change out from under
it (feature_extractor was still at `ALIGN_DEPTH=3` when D28 was written and
verified). Neither contract's author had the finished state of the other in
front of them. This is the same class of gap D27 itself is about — a fix
that is correct and independently verified in isolation can still fail once
composed with a different, also-independently-correct fix, and only a real
synthesis of the COMBINED design surfaces it.

**Fixed (2026-09-05).** The implemented contract (`risk_engine_gate_pipeline
_fix.md`) takes a slightly different shape than this entry's "likely
direction": instead of registering the delay line's `a_*` snapshot outputs
one more cycle, the module now registers the NINE GATE BOOLEANS after the
full stage-1 evaluation and computes the reject-reason priority mux + accept
decision from them one cycle later (stage 2, shallow). Same net effect --
the deep u_gate_align-fed arithmetic no longer shares a cycle with the
9-way priority mux / position-write CE -- and it leaves the already-correct
D28 snapshot timing untouched. Adds one more cycle to `risk_engine.v`'s
`sig_valid`-to-`order_valid` latency (now 2); the `order_builder.v`
`TRIGGER_DELAY` in `tob_top.v` was bumped `2+ALIGN_DEPTH` -> `3+ALIGN_DEPTH`
to match. Consequence, documented and regression-tested (T300/T301): gate
0x03's position-ledger update now commits 2 cycles after `sig_valid`, so two
same-slot aligned intents need >= 2 cycles of spacing for the second's
position check to see the first's update (at 1-cycle spacing it misses it --
same class of tradeoff D28 documented for NFR-5; fine at NFR-4's 16-cycle
nominal spacing). Vivado re-synthesis of the combined design is the next
step, per the contract's acceptance.

---

## D35 — `latency_histogram.v`'s `hist_mem` inferred as 3030 loose registers, not any memory primitive; fixed directly (RTL, independent of the D26-D34 timing work)

**Status: applied and independently verified.** Same external audit
(Opus), a lower-severity item worked on in parallel with the in-flight
timing contracts, deliberately touching neither `risk_engine.v` nor
`tob_top.v` while `risk_engine_gate_pipeline_fix.md` (D34) was in progress
elsewhere.

**Confirmed, not assumed:** a standalone synthesis of `latency_histogram.v`
alone (`xc7a35tfgg484-2`) showed `hist_mem` mapping to **3030 raw
FDCE/LUT/CARRY4/MUXF7/MUXF8 cells — zero memory primitives of any kind**,
not even distributed RAM. Root cause: the write port's reset and
`cfg_counter_clear` paths each swept all 64 entries to zero in a single
clock cycle. A memory (block RAM or distributed RAM) has exactly one write
address per port per cycle; a single-cycle "write all 64 addresses at
once" always-block is not representable by any real memory primitive, so
Vivado fell back to one flip-flop per bit of storage (2048 bits) plus the
comparator/mux logic for the saturating increment — the 3030-cell count
this produces.

**Fix:** both reset and `cfg_counter_clear` now trigger a `clearing` FSM
(`rtl/latency_histogram.v`) that walks addresses 0..63 sequentially over 64
cycles, writing zero to exactly one address per cycle through the same
write port normal increments use. Confirmed post-fix: **22 `RAM64M`
primitives, 310 total cells** — real memory inference, a ~10x reduction in
cell count.

**Real, deliberate consequence, not swept under the rug:** clearing is no
longer instantaneous. A `lat_valid` pulse arriving while `clearing` is high
(the ~64 cycles right after reset or an operator-issued counter-clear) is
dropped, not queued. This only matters in that narrow window, never during
normal operation, and is exercised directly by a new dynamic regression
(`tb/tb_latency_histogram.v` H9) — independently mutation-tested: a
version of the fix that let increments through during the clear sweep was
confirmed to fail H9 with the exact wrong-count signature before this
fix's test was trusted.

**The BRAM-vs-distributed-RAM question, resolved explicitly, not left
open:** the fixed memory infers as **distributed RAM (LUT-based `RAM64M`),
not a block RAM tile** — Vivado's own, reasonable default for a structure
this small (64x32 = 2Kb, well below where a full 18Kb/36Kb BRAM tile stops
being wasteful). FR-54's literal wording says "BRAM histogram." Presented
this tradeoff explicitly rather than picking a side: forcing `(* ram_style
= "block" *)` would literally match the spec's words at the cost of one of
NFR-7's scarce 8-tile BRAM36 budget for a fairly modest histogram. **User
decision: keep distributed RAM** — more resource-efficient, and the actual
bug (no memory inference at all) is what mattered. `fpga_tick_to_trade_
master_spec.md` FR-54 updated with a brief clarifying parenthetical
pointing here; the many *downstream* mentions of "BRAM histogram" (README,
`rtl/README.md`, `docs/contracts/*.md`, `project_explained_simple.md`,
`scripts/make_slides.py`) were deliberately NOT swept in this pass — the
master spec is the single source of truth per CLAUDE.md, and chasing every
downstream reference was out of scope for this fix; flagged here for a
future documentation pass if wanted.

**Verification:** `tb_latency_histogram` (including new H9) passes; full
`iverilog` regression (`bash scripts/run_sim.sh`, `RUN_SIM_FAST=1`) passes
with everything else in flight (D26/D27 v2, D28) unaffected -- this fix
touches only `rtl/latency_histogram.v` and its own testbench, confirmed by
`git diff` scope.

---

## D36 — D34's fix lands; a THIRD, pre-existing bottleneck is exposed (signal_engine.v's front-end), not yet fixed

**Status: found, not yet fixed.** Independently verified D34
(`risk_engine_gate_pipeline_fix.md`) against the real routed netlist, same
discipline as D33/D34's own verification: reintroduced the D34 bug on a copy
and confirmed `tb_risk_engine.v`'s new T300/T301 (and dozens of other cases)
correctly fail; ran `tb_risk_engine` at `ALIGN_DEPTH` 3/4/5/6 myself; ran the
full `iverilog` regression including the 1M soak.

**Real Vivado synthesis of the fully combined design** (D26/D27 v2 +
D28 + D34 + D35, all independently verified in isolation) measured
**post-route WNS = -0.933 ns** — down from -2.282 ns (D34's own baseline)
and, cumulatively, from -9.127 ns before any of this session's timing work
(D26). `risk_engine.v` is no longer on the critical path at all.

**The new worst path is a different module entirely, and pre-dates all of
today's fixes:**

```
u_csr/cfg_symbol_en_reg[0]/C -> u_sig/sig_price_reg[11]/CE
Slack: -0.933 ns. Logic Levels: 12 (CARRY4=4 LUT4=5 LUT5=1 LUT6=2)
Data Path Delay: 8.668 ns (logic 2.569 ns, route 6.099 ns)
```

Traced from the actual routed path: `cfg_symbol_en` (a CSR config register)
feeds `symbol_filter.v`'s slot-match logic, which feeds `tob_engine.v`'s
per-slot book-state selection, which feeds `signal_engine.v`'s `spread_ok`
comparison (a `CARRY4` chain), all the way to `sig_valid`/`sig_price`'s own
registers — one uninterrupted combinational cone from symbol decode through
book-state selection to the deterministic trading decision.

**This is not new, and not caused by D26-D35.** It is the same front-end
cone flagged by the same external audit *before* D26/D27 v2 was even
implemented ("the front-end cone is untouched by v2 and already eats ~4.7 ns
... it should close, but not comfortably ... if v2 misses, that cone is
where v3 goes"). It was already tight; `feature_extractor.v` also reads off
this exact same chain (`tob_engine.v`'s `next_*` ports) and happened to be
the *more* violated path until D26/D27 v2 fixed it. With that fixed, this
pre-existing, always-marginal front-end cone is now the tightest remaining
constraint — exposed, not introduced.

**Why this is not a quick surgical fix like D26/D27/D34, and not attempted
in this session:** D26/D27 (F1 in `feature_extractor.v`) and D34 (the gate
vector in `risk_engine.v`) were each contained inside ONE module's own
internal computation — a register could be inserted without touching any
other module's interface or the fixed-latency assumptions the rest of the
datapath depends on. This path is different: it runs *through* the shared
convention every downstream consumer of `tob_engine.v`'s `next_*` ports and
`book_upd_valid` currently relies on (that a message's post-update book
state is combinationally available the same cycle it's applied, D23's own
fix). Breaking this cone would mean registering `symbol_filter.v`'s match
decision (or an equivalent boundary) before `tob_engine.v` consumes it —
which changes the cycle-relationship EVERY downstream module
(`feature_extractor.v`, `signal_engine.v`, `risk_engine.v` via `bid_price`/
`ask_price`) assumes, not just one module's own latency. That is a
materially bigger, more foundational change than any of this session's
three fixes, and deserves its own dedicated design pass, not a rushed
extension of D34's contract.

**Not yet resolved.** Recorded here so it is not lost, matching this
project's standing discipline of writing down what was found even when the
fix is deferred (D8, D25's initial half, D28 before its own fix landed).

---

## D37 — D36's fix lands: full timing closure achieved (WNS = +0.074 ns)

**Status: fixed and closed.** Per explicit direction to implement D36
directly (not as an external contract), added a front-end pipeline register
inside `tob_engine.v` that captures `filt_valid`/`filt_slot`/`err_seq_dup`/
`msg_type`/`msg_side`/`msg_price`/`msg_quantity` one cycle before any of
`tob_engine.v`'s own combinational logic (`is_quote`/`is_clear`/book-state
selection) consumes them. This moves the D36 front-end cone's registration
boundary from *after* `symbol_filter.v`'s slot-match decision (unregistered,
feeding straight into `tob_engine.v` and then `signal_engine.v` in the same
cycle) to *before* `tob_engine.v`'s own decode logic, breaking the single
12-level combinational cone D36 identified
(`cfg_symbol_en_reg[0]/C -> sig_price_reg[11]/CE`) into two shorter stages.

**Two ripple effects were identified and handled up front, before writing
any RTL**, to avoid a repeat of the D26/D27 "found it the hard way in
Vivado" pattern:

1. `feature_extractor.v` previously read `msg_type`/`msg_side` directly from
   `md_parser` (`md_msg_type`/`md_msg_side`), not through `tob_engine.v`.
   Left as-is, those signals would now be one cycle ahead of
   `msg_applied`/`book_upd_valid` (which are driven off the new registered
   copies). Fixed by adding registered passthrough outputs
   `applied_msg_type`/`applied_msg_side` from `tob_engine.v` and rewiring
   `tob_top.v`'s `feature_extractor` instantiation to consume those instead
   of the raw `md_parser` signals — restoring the same-cycle alignment
   `feature_extractor.v` depends on.
2. `order_builder.v`'s `TRIGGER_DELAY` parameter (an unconditional delay
   line that re-delays `msg_seq_num`/`cur_cycle` so `trigger_seq`/
   `latency_cyc` report the original triggering message, not whatever is in
   flight when the order fires) is calibrated against the *total* cycle
   count from `md_parser`'s `msg_valid` to `order_valid`. `tob_engine.v`'s
   new front-end register adds one more cycle before `signal_engine.v` even
   starts. `tob_top.v`'s `TRIGGER_DELAY` was bumped from `3 + ALIGN_DEPTH`
   (D34's value) to `4 + ALIGN_DEPTH` accordingly.

`ALIGN_DEPTH` itself (5, set by D26/D27 v2) is unaffected — D36 adds
internal-to-module latency on both the signal and ML branches equally
upstream of the alignment stage's own inputs, it doesn't change the
alignment relationship `ALIGN_DEPTH` corrects for.

**Independent verification performed** (same discipline as every prior fix
this session):

- Diff-reviewed the full `tob_engine.v` rewrite and the `tob_top.v` ripple
  (new ports, `feature_extractor` rewiring, `TRIGGER_DELAY` bump) myself —
  self-implemented, so this is a self-review rather than reviewing another
  party's report, but performed with the same rigor.
- Updated all four affected testbenches (`tb_tob_engine.v`,
  `tb_feature_tob_chain.v`, `tb_signal_tob_chain.v`, `tb_ml_chain.v`) to
  insert the additional pipeline cycle into each `fire` task's P0/N0.5/P1
  drive sequence. `tb_ml_chain.v` was the one case that surfaced a real
  failure before its own fix was applied (mismatches on `z`/`slot`/etc.)
  because its `msg_type`/`msg_side` wiring and timing hadn't yet been
  updated — fixed by applying the same rewiring/timing change used in the
  other three chains; re-ran and confirmed PASS.
- Added a dedicated `tb_tob_engine.v` back-to-back regression: message B's
  inputs load on exactly message A's own P1 (commit) cycle, with no idle
  gap, then checks that `applied_msg_type`/`applied_msg_side` still report
  A's values at A's capture point and only flip to B's on B's own P1. This
  is the one case that actually exercises the new register's registered
  (vs. combinational-passthrough) behavior — every pre-existing test case
  holds `msg_type`/`msg_side` constant across P0→P1, so none of them would
  have caught a mutation that made `applied_msg_type` a live wire.
- **Mutation-tested the new check itself**, and caught my own first attempt
  at it being non-discriminating: mutating `applied_msg_type` to
  `assign applied_msg_type = msg_type;` (unregistered) against the
  pre-existing test suite produced no failures, because none of those
  cases change `msg_type` between P0 and P1 — the testbench's own
  register still held the right value at P1 regardless of the mutation.
  Only after adding the back-to-back case above did the same mutation
  correctly fail (`FAIL: D36 back-to-back A: applied_msg_type=2/
  applied_msg_side=1, expected QUOTE/SIDE_BID`).
- Full `iverilog` regression (`scripts/run_sim.sh`), including the
  1,000,000-message parser soak: **all tests pass.**
- **Real Vivado synthesis + implementation (place & route) of the fully
  combined design** (D26/D27 v2 + D28 + D34 + D35 + D36, all previously
  verified individually) — the only way to authoritatively confirm timing
  closure, since none of DeepSeek/GLM nor `iverilog` can produce a routed
  timing report:

  ```
  === 时序分析摘要 === 状态: PASS (时序满足)
    Setup  WNS = +0.074 ns   TNS = 0.000 ns
           失败端点: 0 / 30865
    Hold   WHS = +0.037 ns   THS = 0.000 ns
  ```

  Worst (but now met) path: `u_tob/p_msg_quantity_reg[7]/C ->
  u_sig/sig_price_reg[10]/CE` — directly confirming the new front-end
  register is the tightest remaining constraint, and that it closes.

**Cumulative WNS timeline this session:**

| Stage | WNS | Status |
| :-- | :-- | :-- |
| D26 baseline (before any fix) | -9.127 ns | failing |
| D27 v1 (half-window split, abandoned) | -8.277 ns | failing |
| D26/D27 v2 + D28 (feature_extractor pipeline) | -2.282 ns | failing |
| D34 (risk_engine gate-vector pipeline) | -0.933 ns | failing |
| **D36 (tob_engine front-end register)** | **+0.074 ns** | **PASS** |

**Utilization improved alongside timing** (mostly from the D28/`latency_
histogram.v` fix, not D36 itself): Slice LUTs 9671/20800 (46.50%, down from
58.21% earlier this session), Slice Registers 11091/41600 (26.66%).
Latch count unchanged at 32 (still the open `token_bucket` issue below); 0
blackboxes.

**This closes the multi-session timing-closure saga that began at D26.**
Two important caveats, in the interest of not overstating the result:

1. **The margin is thin (+0.074 ns setup, +0.037 ns hold)** — comfortably
   inside Vivado's routed-result variance across otherwise-identical runs,
   and easily erased by any future RTL change that adds even one more gate
   to either of the two paths now tied for worst. Any future change to
   `tob_engine.v`, `signal_engine.v`, `csr_block.v`, or `symbol_filter.v`
   should be re-verified against a fresh routed timing report, not assumed
   safe by resemblance to a previously-closed change.
2. **Timing closure alone does not unblock `scripts/build.tcl`/`make
   bit`.** The `token_bucket`/`refill_ctr` latch issue in `risk_engine.v`
   (flagged D28/D29, root cause still not identified — why Vivado infers
   `LDCE` latches from a seemingly-clean synchronous always-block) is a
   separate, still-open defect that a bitstream-readiness check would
   independently reject regardless of timing. Producing an actual
   gate-passing bitstream still requires that investigation to land first.

---

## D38 — `token_bucket`'s 32 `LDCE` latches (D28/D29): root cause found and fixed — async reset to a non-constant value

**Status: fixed and verified.** Per direction to investigate the
`token_bucket`/`refill_ctr` latch issue directly, root-caused and fixed —
not guessed at from the RTL alone, but reproduced in isolation in real
Vivado first, exactly as this project's standing discipline requires for
anything only Vivado can confirm.

**Root cause:** `risk_engine.v`'s reset branch had
`token_bucket <= cfg_token_max;` — `cfg_token_max` is a live CSR input
(`input wire [31:0] cfg_token_max`), not a compile-time constant.
Xilinx 7-series flip-flop primitives (`FDCE`/`FDPE`/`FDRE`) only support an
asynchronous set or clear to a **hardwired constant** (0 or 1) — there is
no primitive for "asynchronously load this runtime value on reset." Since
Vivado cannot know at synthesis time whether any given bit of
`cfg_token_max` will be 0 or 1, it cannot pick a single primitive per bit;
instead it builds each bit from a small set/clear-flip-flop pair muxed
through a transparent latch (`LDCE`), selected by that bit's live runtime
value. `refill_ctr`, in the same always block, resets to the genuine
constant `32'd0` and was untouched — exactly why only `token_bucket`'s 32
bits, not `refill_ctr`'s, showed up as latches (D28/D29's own observation,
now explained).

**Confirmed directly, not inferred:** synthesizing a two-line isolated
repro of the exact pattern reproduced the identical 32 `LDCE` cells and
surfaced the diagnostic Vivado had been emitting all along:
`WARNING: [Synth 8-7137] Register token_bucket_reg ... has both Set and
reset with same priority. This may cause simulation mismatches.` A second
repro with the fix below produced 0 latches and 0 warnings, confirmed
before touching the real file.

**Fix:** keep the async reset itself a plain constant (`token_bucket <=
32'd0;`), and add a one-bit `boot_done` flag (also constant-reset, `1'b0`).
A combinational `token_bucket_eff = boot_done ? token_bucket :
cfg_token_max` substitutes `cfg_token_max` for the *effective* bucket value
everywhere the old code read `token_bucket`, for as long as `boot_done` is
low — i.e. for the entire reset-held window and through the first active
clock edge after release, exactly matching the old semantics (the register
being reset to `cfg_token_max` was only ever observable starting at that
same first post-reset edge; `boot_done`'s own reset value guarantees
`token_bucket_eff` reads `cfg_token_max` at that identical moment, refill/
accept logic included, since it's a combinational substitution evaluated
every cycle, not a one-shot load). `boot_done <= 1'b1` unconditionally in
the non-reset branch, so the substitution only ever applies during/
immediately after reset. Both registers are now genuine constant-reset
`FDCE`s.

**Verified:**
- Full `iverilog` regression (`scripts/run_sim.sh`): all tests pass,
  including `tb_risk_engine.v`'s dedicated token-bucket cases (T19, plus
  the reset-proves-bucket-is-full case and cases E's `cfg_token_max` =
  2/8/100 sweep) — none needed to change, confirming the fix is behavior-
  preserving by construction, not just by coincidence.
- **Mutation-tested**: reverted `token_bucket_eff` to a bare
  `= token_bucket` (dropping the `boot_done` substitution) on a scratch
  copy — `tb_risk_engine.v` immediately failed with dozens of cascading
  mismatches starting at the very first reset case (`T81`, `T82`, `T90`,
  `T300`/`T301`'s poison-message regressions, etc.), confirming the test
  suite genuinely discriminates on this exact change.
- **Real Vivado synthesis of the full board-level design**: 0 cells match
  `PRIMITIVE_SUBGROUP == LATCH` (was 32), both pre- and post-route. 0
  blackboxes. Full place & route completed with 0 errors; timing
  independently reconfirmed closed on this design (see D39 for the final
  authoritative numbers, since D39's pin-constraint fix was verified in the
  same run immediately after this one).

**This closes the last item from D28/D29's "still open" list** — the only
remaining gap before a real `make bit` run was D39's discovery, below,
found while re-running the build specifically to prove D38 end-to-end.

---

## D39 — `constraints/tob_pins.xdc`: 15 of 22 board pins were silently unconstrained — trailing inline comments broke `set_property`, not a comment at all to Vivado's parser

**Status: fixed and verified.** Found while attempting the first-ever real
`write_bitstream` on this design (only possible now that D38 cleared the
latch gate and timing was independently closed) — a step nobody had reason
to attempt before, since `build.tcl` always exited at an earlier gate.

**The bug:** every RGMII/MDIO/`phy_reset_n` line in `tob_pins.xdc` was
written as `set_property PACKAGE_PIN <pin> [get_ports <port>]   # <label>`
— a trailing comment on the *same* line as the command, e.g.
`set_property PACKAGE_PIN J21 [get_ports {rgmii_txd[0]}]   # E1_TXD0`. In
Tcl, `#` is only treated as a comment where a **new command** is expected
(start of a line, or after a `;`) — not after a command's own arguments
have already begun on that same line. Confirmed directly: evaluating one
of these exact lines on its own in a live Vivado session throws
`ERROR: [Common 17-161] Invalid option value '#' specified for
'objects'.` — Vivado's `set_property` parses the `#` as a literal
(invalid) extra object name, not a comment, and the *entire command
fails*, so the `PACKAGE_PIN` was never applied for that port.
`read_xdc` swallows this per-line failure and keeps loading the rest of
the file, so the file appeared to load cleanly (no error surfaced from
`read_xdc` itself) while these exact 15 ports — `rgmii_txd[3:0]`,
`rgmii_tx_ctl`, `rgmii_txc`, `rgmii_rxd[3:0]`, `rgmii_rx_ctl`, `rgmii_rxc`,
`mdc`, `mdio`, `phy_reset_n` — silently kept whatever `PACKAGE_PIN` the
placer auto-assigned instead of the schematic-verified pin from
`docs/refs/AX7035B_pinout_notes.md`. Only `write_bitstream`'s own DRC
(`UCIO-1`, "Unconstrained Logical Port") ever surfaces this, and nothing
before D38 had gotten far enough to run `write_bitstream` at all.

**Why this matters beyond "wrong pin numbers":** this isn't cosmetic.
Placing RGMII/MDIO signals on whatever pin the placer happens to pick,
rather than the pins actually wired to the PHY on the board, would produce
a bitstream that drives real board pins with no connection to (or the
wrong connection to) the JL2121(D) PHY — at best non-functional, at worst,
per DRC UCIO-1's own wording, a genuine I/O-contention/damage risk if any
of those auto-picked pins are already strapped to something else on the
board. This would not have been caught by simulation (Icarus has no
concept of package pins) or by `report_timing`/latch checks — only a real
`write_bitstream` DRC catches it, and only once something finally got far
enough to run one.

**Fix:** moved every trailing comment onto its own line; no `PACKAGE_PIN`/
`IOSTANDARD`/`SLEW` value changed, only the comment placement. The
non-RGMII portion of the same file (`sys_clk`/`rst_n`/`led`/`key_in`,
lines 18-43) never had this pattern and was already correct — consistent
with only the RGMII/MDIO block being affected.

**Verified:** re-ran the full non-project-mode flow from a clean
`create_project -in_memory`: `get_property PACKAGE_PIN` for every affected
port now returns exactly the XDC's intended value (`rgmii_txd[0]` → `J21`,
`rgmii_rx_ctl` → `M21`, `mdio` → `K16`, etc.), and a direct sweep over
every port on the design (`get_ports`) found zero with an empty
`PACKAGE_PIN` — matching the DRC's own "22 logical ports" count with none
now unconstrained.

**A new, small timing regression surfaced by this fix — not yet closed,
see D40.** Correcting the RGMII pins' physical placement measurably shifts
routing for everything electrically close to them (the `gmii_rx_clk`
buffer's own physical fan-out tree in particular), which changed the
routed delay balance just enough to flip the previously-closed design
(D38's own re-verification: WNS = +0.092 ns) into a small violation
(WNS = -0.129 ns, 21/30802 endpoints) on the very next place & route after
this fix. This is not a sign the pin fix is wrong — an incorrect pin
placement is not an acceptable trade for a closed timing report — it is
exactly the kind of thin-margin fragility D37 already flagged ("easily
erased by any future RTL change"); a legitimate constraint fix turned out
to be enough on its own. See D40.

---

## D40 — Fixing D39's pin constraints reopens timing by a small margin: two more bottlenecks (`feature_extractor.v`'s F3, `signal_engine.v`'s whole decision) found AND fixed — first real, gate-passing bitstream ever produced for this design

**Status: fixed and verified, bitstream generated.** Discovered immediately
after D39's fix, in the same re-verification run.

**The new worst path:**

```
u_tob/p_msg_side_reg[4]/C -> u_feat/p1_f3_reg[12]/D
Slack: -0.129 ns. Logic Levels: 15 (CARRY4=10 LUT4=3 LUT6=2)
Data Path Delay: 8.023 ns (logic 3.153 ns, route 4.870 ns)
```

Traced from the actual routed path: D36's `p_msg_side` register (inside
`tob_engine.v`) feeds book-state selection logic (`prev_ap`/`prev_bp`/
`prev_bq`), which feeds an 8-deep `CARRY4` chain computing `p1_f3` —
`feature_extractor.v`'s **F3** feature (`sat_signed(bid_qty -
prev_bid_qty)`, [feature_extractor.v:78](rtl/feature_extractor.v:78)) —
landing in `p1_f3`'s own pipeline register
([feature_extractor.v:410](rtl/feature_extractor.v:410)). Names like
`u_tob/p1_f3[12]_i_1` in the routed netlist are the same hierarchy-
flattening naming artifact flagged since D26: the LUT physically sits in
`u_tob`'s placed region, but it's logically part of `feature_extractor.v`'s
F3 computation.

**Why this is a *fourth*, previously-undiscovered bottleneck, not a
regression in anything D26-D39 touched:** D33's fix (`feature_extractor_
timing_patch.md`) closed **F1/F5/F7** specifically — its own title says
so. F3 (along with F0/F2/F4/F6) was never part of that contract's scope,
because at the time, F1 alone was so much worse (part of the original
-9.127 ns D26 baseline) that F3's own margin was never the limiting
factor. Every fix since (D28, D34, D35, D36, D38, D39) closed *other*
paths without ever touching F3's own logic or its inputs' arrival time —
until D39 changed the physical placement of the RGMII pin feeding
`gmii_rx_clk`'s buffer, which shifted clock-tree routing delay balance
across the whole design by a few hundredths of a nanosecond. F3's margin,
it turns out, was thin in exactly the same way D36's front-end cone was
thin before D36 — sitting just under the line, until something upstream
that F3 doesn't itself touch (a correct, necessary pin-placement fix) moved
the line under it.

**Checking for a structural twin before fixing (avoiding D36's own earlier
miss):** F4 (`sat_sub(ask_qty, prev_ask_qty)`) is architecturally identical
to F3, differing only in which book side it reads. Measured its own worst
path directly (`report_timing -from u_tob/p_msg_side_reg[*]/C -to
u_feat/p1_f4_reg[*]/D`) before deciding scope: **+0.478 ns**, comfortably
positive — different physical routing (shorter route delay, same logic
levels) happened to leave it with real margin. Left untouched; only what
was actually violating got fixed.

**F3's fix** (`rtl/feature_extractor.v`): the identical technique D26/D27
v2 already used for F1 — split "compute the wide operand" from "subtract
already-registered operands" across a cycle boundary, since F3 already had
a spare pipeline stage to reuse (stage 1, where F1's own subtract lives).
`sbq` (this event's post-update bid qty, `next_bid_qty`) and this slot's
`prev_bq` are now registered as-is into `p1_sbq`/`p1_prev_bq`
([feature_extractor.v:258](rtl/feature_extractor.v:258)) at the stage-0→1
boundary instead of being subtracted immediately; the actual `sat_sub`
moves into stage 1 alongside F1's own subtract
([feature_extractor.v:276](rtl/feature_extractor.v:276)), operating on two
plain registers instead of chaining off `tob_engine.v`'s live `next_bid_qty`
derivation. `feat_valid`'s total latency (3 cycles after `book_upd_valid`)
is unchanged — F3 moved from "computed in stage 0, passed through stage 2"
to "registered in stage 0, computed in stage 1, registered into stage 2",
same total depth.

**`signal_engine.v`'s violation was a second, independent finding in the
same re-verification run** (`u_tob/p_msg_quantity_reg[15]/C ->
u_sig/sig_price_reg[*]/CE` and `.../sig_qty_reg[*]/CE`, worst -0.062 ns,
13 endpoints) — the whole `spread_ok`/`buy_qty_ok`/`sell_qty_ok`/`conflict`
decision chained directly off `tob_engine.v`'s live `next_bid_price`/
`next_ask_price`/`next_bid_qty`/`next_ask_qty` in ONE cycle, all the way to
`sig_valid`/`sig_price`'s own registers. Unlike F1/F3, this module had no
spare pipeline stage to reuse (it was always a single combinational block
feeding one output register) — closing it needed a genuine extra cycle,
not just moved work. Fix: a new stage 0 registers the raw `next_*`/
`book_upd_valid`/`applied_slot` inputs as-is (cheap, no chain); stage 1
computes the D15 wide-precision shift, `spread_ok`, and `conflict` from
those now-registered operands and drives `sig_*`
([signal_engine.v:131-234](rtl/signal_engine.v:131)). `sig_valid` now
registers **two** cycles after `book_upd_valid`, not one.

**Ripple, handled before writing any RTL (same discipline as D36):**
`tob_top.v`'s `ALIGN_DEPTH` — whose entire job is `ML_branch_total -
signal_branch_own_latency` so the signal and ML branches land on
`risk_engine.v` the same cycle — decreases by exactly the same amount
`signal_engine.v`'s own latency increased: **5 → 4**. `order_builder.v`'s
`TRIGGER_DELAY` (calibrated against the *total*, unconditional
`md_parser`→`order_valid` cycle count, which `ALIGN_DEPTH`'s compensating
decrease leaves unchanged) goes from `4 + ALIGN_DEPTH` to `5 + ALIGN_DEPTH`
— same absolute value (9), reallocated between the two terms
([tob_top.v:472](rtl/tob_top.v:472), [tob_top.v:697](rtl/tob_top.v:697)).

**Independent verification:** `tb_feature_extractor.v`, `tb_signal_engine.v`,
`tb_signal_tob_chain.v`, `tb_feature_tob_chain.v`, `tb_ml_chain.v`, and
`tb_tob_top.v` all updated for the new pipeline depths; full `iverilog`
regression (`scripts/run_sim.sh`), including the 1,000,000-message parser
soak, passes clean. Both fixes were mutation-tested (reintroducing the
pre-fix combinational structure on scratch copies) to confirm the updated
testbenches actually discriminate on the change, not just pass by
coincidence with the old timing.

**Real Vivado synthesis + implementation of the fully combined design**
(D26/D27 v2 + D28 + D34 + D35 + D36 + D38 + D39 + D40, all independently
verified) — the definitive signoff:

```
=== 时序分析摘要 === 状态: PASS (时序满足)
  Setup  WNS = +0.141 ns   TNS = 0.000 ns
         失败端点: 0 / 31058
  Hold   WHS = +0.043 ns   THS = 0.000 ns
```

Neither of D40's two fixed paths appears anywhere in the new top-6 critical
path list — the worst path is now a third, previously-unseen and much more
comfortably-marginal cone (`u_ob/tx_payload_reg[8]/C ->
u_hist/hist_mem_reg.../RAMB/I`, order_builder into the latency-histogram
BRAM), confirming the classic pattern continues but with healthy remaining
margin this time. 0 inferred latches (`PRIMITIVE_SUBGROUP == LATCH`), 0
blackboxes. Utilization: Slice LUTs 9511/20800 (45.73%), Slice Registers
11156/41600 (26.82%) — both essentially flat vs. D38/D39, as expected for
two small pipeline-register insertions.

**With D39's pin constraints now correctly binding real physical pins and
timing/latches both closed, `write_bitstream` was run for the first time
in this project's history and completed successfully**:
`results/build/tob_top.bit`, 2,192,115 bytes, `DRC finished with 0 Errors`,
`Bitgen Completed Successfully`. This is the first real, gate-passing
bitstream this design has ever produced — S11 hardware bring-up's
bitstream-generation blocker (D28/D29/D38's `token_bucket` latch, D39's
silently-unconstrained pins, and now D40's timing) is fully cleared. Actual
physical board bring-up (JTAG program, PHY link-up, live traffic) is a
separate, not-yet-attempted next step — this milestone is "a real
bitstream exists and passes every automated gate `build.tcl` checks," not
"verified on hardware."

---

## D41 — NFR-7 revisited with real post-implementation data: the vendored MAC alone does not explain the overshoot; `csr_block.v` is the single largest hand-written contributor

**Status: documented (spec text updated), not fixed.** D32 recorded NFR-7's
violation from synthesis-only numbers and *hypothesized* the vendored MAC
(D1) as the main cause, deliberately not chased further at the time (no
post-implementation build existed yet to check against). D40's bitstream
milestone finally produced one; this entry replaces the hypothesis with
measured, hierarchical data (`report_utilization -hierarchical
-hierarchical_depth 2`, the routed D40 netlist).

**The hypothesis was only partly right.** Excluding the entire vendored MAC
datapath (`u_mac` 2313 LUTs/2548 FFs, plus its RGMII/byte-stream adapters
`u_eth_if` 133/181 and `u_phy_if` 6/27 — 2452 LUTs / 2756 FFs total) brings
engine LUTs from the whole-design 45.73% down to **33.94%** (7,059 /
20,800) — still **more than 2x** NFR-7's ≤15% budget. FFs: 26.82% → 20.19%
(8,400 / 41,600), also still 2x the ≤10% budget. The vendored MAC is real
and legitimate to carve out (same rationale as the ML classifier's own
carve-out — D1 was a deliberate, already-justified tradeoff made after
NFR-7's number was fixed), but it is not, on its own, the explanation.

**`csr_block.v` (`u_csr`) is the single largest hand-written contributor**:
2,335 LUTs / 2,253 FFs — **11.2% of the entire part's LUT fabric**, bigger
than the entire vendored MAC stack. For comparison, the next largest
engine-only contributors: `u_feat` (feature_extractor.v) 1,680 LUTs, `u_tob`
(tob_engine.v) 842, `u_align` (the top-level `ALIGN_DEPTH` delay line) 468,
`u_risk` (risk_engine.v, including its own D28 delay line) 552, `u_ob`
(order_builder.v) 396, `u_norm` 306, `u_sig` 232. `csr_block.v` alone is
larger than any two of these combined — genuinely disproportionate for a
control/status-register and counter block, and the natural place to look if
this budget is ever chased for real (not attempted here — root-causing
*why* a register/counter block costs this many LUTs is a real
investigation, not a quick fix, per the same reasoning D26 gave for not
rushing a timing fix into an under-scoped contract).

**Resolution (per explicit user decision):** document the gap honestly
rather than chase it now. `fpga_tick_to_trade_master_spec.md`'s NFR-7 text
now explicitly carves out the vendored MAC/PHY datapath (matching the
ML-classifier precedent) and points here for the measured reality. The
`csr_block.v` finding is flagged for a future, dedicated investigation —
not attempted in this entry.

---

## D42 — D30's reduce-mode `cnt_rej_ml` question resolved: spec wording corrected, no behavior change

**Status: resolved (spec text only).** D30 flagged that the master spec's
§10 counter table literally read "gate `0x09` blocked/**reduced**" for
`cnt_rej_ml`, while both the RTL (`gate_ml_fired_c = adverse_risk &
~cfg_ml_action`, firing only in block mode) and the golden model only ever
count block-mode ML actions. D30 deliberately left this open as a
normative-text question rather than silently editing the spec.

**Resolution:** `cnt_rej_ml` counts block-mode ML actions only. A
reduce-mode action still sets `order_valid=1` with a resized quantity — per
FR-48's own framing, "the ML reduction is gate `0x09`'s own action,"
distinct from every other gate's outright rejection — so it was never
actually rejected, just resized, and counting it under a "rejection"
counter would misrepresent it even taken literally. **No RTL or golden-model
change**: both already implement exactly this behavior; only
`fpga_tick_to_trade_master_spec.md` §10's `cnt_rej_ml` description was
imprecise. Updated to read "gate `0x09` block-mode only," with the
resize-vs-reject distinction spelled out inline.

---

## D43 — `ml_policy.v`'s D28-class bug (flagged, deferred at D28) fixed via `docs/contracts/ml_policy_align_fix.md`

**Status: fixed and independently verified.** Implemented by DeepSeek from
a self-contained contract (parallel workstream alongside D44's `tb/tb_top.v`
work, deliberately non-overlapping files: this touches `rtl/ml_policy.v` +
one two-line addition to `rtl/tob_top.v`'s existing `ml_policy`
instantiation + `tb/tb_ml_policy.v`). Per this project's standing rule,
verified independently before accepting the report — including from another
AI — not taken on trust.

**The bug** (flagged in D28's own text, explicitly out of scope for that
contract): `ml_policy.v` read `bid_valid`/`ask_valid`/`crossed` **live** at
`ml_slot`, the identical stale-alignment bug D28 fixed in `risk_engine.v`.
The ML branch has no alignment stage between the triggering message and
`ml_valid` (unlike the signal branch, which passes through `u_align`), so
`ml_valid` fires 5 cycles after the triggering message's own
`book_upd_valid` (`feature_extractor.v`'s 3 + `feature_normalizer.v`'s 1 +
`ml_classifier_wrap.v`'s 1) — comfortably long enough for an intervening
message on the same slot to have already changed that slot's
validity/crossed state by the time `ml_policy.v` evaluates it.

**The fix**, mirroring D28's own risk_engine.v pattern exactly: the
triggering message's own `book_upd_valid`/`applied_slot` (already top-level
wires in `tob_top.v` — `u_feat` already consumes both) are registered one
cycle (`raw_d1_valid`/`raw_d1_slot`, capturing exactly at T+1, the same
cycle D23 guarantees `bid_valid`/`ask_valid`/`crossed` are correct for THIS
message), then an internal `delay_line` (`u_fs_align`, `WIDTH=3`,
`DEPTH=SNAPSHOT_DEPTH`) carries that snapshot forward so it arrives already
time-correct on the cycle `ml_valid` fires for the same message.
`SNAPSHOT_DEPTH` (a new module parameter, default 4) is
**deliberately not tied to `tob_top.v`'s `ALIGN_DEPTH`** — despite both
happening to equal 4 today, they derive from unrelated relationships
(`ALIGN_DEPTH` = ML-branch-total − signal-branch-latency; `SNAPSHOT_DEPTH`
= ML-branch-total − 1 for the T+1 capture cycle already spent) and a future
change to one must not silently break the other. `seq_gap` is deliberately
NOT snapshotted (feed-wide sticky state, correctly read live).

**Independently verified:**

- Cross-checked `SNAPSHOT_DEPTH=4`'s derivation myself, before looking at
  DeepSeek's own comment: counted the clocked `always` blocks in
  `feature_normalizer.v` and `ml_classifier_wrap.v` (one each — one cycle
  of latency apiece) against `feature_extractor.v`'s known 3-cycle pipeline
  (D33) to independently arrive at the same 4, via the same reasoning,
  before reading the contract's own derivation.
- `tb/tb_ml_policy.v`'s rework runs with a **non-default** `SNAPSHOT_DEPTH`
  (`TB_SNAPSHOT_DEPTH`, default 3, not 4) specifically to prove the
  parameter is genuinely independent of `ALIGN_DEPTH` rather than
  accidentally reusing it; includes a poison-message regression (same
  P1/P2/P3 shape as D28's own) and an always-on assertion that
  `fs_snap_out_valid` coincides with `ml_valid` every cycle.
- **Mutation-tested independently**: reverted `safe_state_c` to read
  `bid_valid[ml_slot]`/`ask_valid[ml_slot]`/`crossed[ml_slot]` live (the
  original bug) on a scratch copy — `tb/tb_ml_policy.v` immediately caught
  it with 6 failing checks.
- Full `iverilog` regression (`scripts/run_sim.sh`) passes with this change
  landed alongside D44's `tb/tb_top.v` (below) — the two contracts'
  non-overlapping file scope meant no merge conflict, confirmed directly
  (`git diff rtl/tob_top.v` showed both changes present cleanly).

---

## D44 — `tb/tb_top.v` (full-system integration test) implemented; found and fixed a genuine `cnt_seq_gap` RTL bug in the process

**Status: implemented, one real bug found and fixed.** Self-implemented
from `docs/contracts/tb_top_integration.md` (parallel workstream alongside
D43's `ml_policy.v` fix). This is the test the project's own audit
correctly flagged as missing (§17/D28/D30's own text: exactly this kind of
full-system comparison would have caught D30's counter bugs and D28's
misalignment without needing an external audit).

**Architecture:** `tob_top.v` is the real DUT; the two vendor leaf modules
it instantiates (`mac_top.v`, `util_gmii_to_rgmii.v`) are the same
behavioral stand-ins `tb/tb_tob_top.v` already uses
(`tb/sim_models/tob_top_sim_leaves.v`), so the test drives at `mac_top.v`'s
UDP boundary — one 16-byte message per injected frame (the stand-in's
`sim_rx_frame` is fixed at 16 bytes; message-level, not frame-packing,
correctness is this test's job — `md_parser.v`'s own testbench already
covers multi-message frame packing). Two parts:

- **Part A** — seven directed, hand-reasoned end-to-end scenarios
  (kill-switch reject, size/position/band/stale/seqgap gate rejects, ML
  gate reduce/block), each predicting the exact TX frame bytes by hand
  before running, the same discipline `tb_tob_top.v`'s existing T1-T7 use.
- **Part B** — a randomized soak: `sim/gen_top_soak_vectors.py` (new)
  drives `feed_gen.py`'s scenario mix through `golden_model.py`, wiring
  `feature_golden.py`'s `FeatureTracker` and `ml_golden.py`'s
  `MLClassifier` THROUGH `golden_model.py`'s injectable `adverse_risk_fn`
  callback — nothing before this file combined all three, since
  `golden_model.py` deliberately doesn't compute ML itself (D31/S1 scope
  split). Two-pass design: a small shadow per-symbol book (replicating
  FR-14/15/16's update rule) drives the ML side one message ahead of when
  `GoldenModel` itself has post-update state, precomputing one
  `adverse_risk` value per message in order for pass 2's real
  `GoldenModel` run to consume.

**Verification, on the test's own output:** 209 injected messages, 81
expected orders, all 81 bit-exact against the golden model on the first
fully-debugged run; 35/35 counters match exactly.

**Two real bugs found and fixed while getting to 35/35 — both in this
generator/methodology, not the RTL, discovered and fixed BEFORE the third
(genuine RTL) bug below was even visible:**

1. **CSR frames are themselves counted traffic.** The 3 setup-CSR-writes
   (ML thresholds) and the 35 sequential CSR-reads used to read back every
   counter are each a real 16-byte frame `md_parser.v` processes exactly
   like a market message — `msg_type` 0x20/0x21 fails `type_ok`, so every
   one increments `cnt_frames_rx`/`cnt_msgs_rx`/`err_msg_type`, and (via
   `seq_monitor.v`, `seq_num=0` on every CSR frame) counts as a duplicate
   once any real traffic has occurred. An initial version of this
   generator snapshotted `golden_model.py`'s counters once, after the real
   stream, accounting for none of this — off by exactly the amount each
   counter's position in the 38-frame sequence (3 writes + up to 35 reads)
   would predict. Fixed by simulating the exact same 38 CSR frames, in the
   exact same order `tb_top.v` itself sends them, through
   `gm.process_frame()`.
2. **Pipeline depth matters even for this bookkeeping**: `cnt_frames_rx`
   (frame-classifier level) reflects a CSR read's own contribution
   immediately, in its own response — but every other counter
   (`md_parser.v`-downstream: `cnt_msgs_rx`, `err_msg_type`, `cnt_seq_gap`,
   `cnt_seq_dup`, etc.) does not yet reflect that same read's own
   contribution when its response is built, only becoming visible starting
   with the NEXT frame. Confirmed directly against real RTL (an initial
   fix modeling every counter the same way as `cnt_frames_rx` was
   consistently 1 too high on every OTHER counter); fixed by snapshotting
   `cnt_frames_rx` after processing its own read frame but every other
   counter from immediately BEFORE processing its own read frame.

**The third, genuine RTL bug, found only after both of the above were
fixed** (real bugs don't announce themselves as "the interesting one" —
this generator-methodology work had to be right first, or a real RTL bug
would have been invisible under the noise, or worse, a methodology bug
could have been mistaken for an RTL one): `cnt_seq_gap` disagreed with the
now-correctly-modeled golden value by a wide margin unrelated to either fix
above (RTL consistently LOWER). Traced to `seq_monitor.v`/`csr_block.v`:
`seq_monitor.v` correctly computes `seq_gap_amount` (`msg_seq_num -
expected_seq`) and its own header already says *"must add seq_gap_amount,
not just increment by 1"* — but that wire, while exposed at the top level
in `tob_top.v`, was never actually connected to `csr_block.v`, which only
ever did `cnt_seq_gap <= satinc(cnt_seq_gap)` (flat +1 per gap event).
Master spec FR-10 is explicit ("increment `cnt_seq_gap` **by the gap**")
and `golden_model.py` already implements it correctly — RTL disagreed with
both, in a case where the correct value was already computed and simply
never wired to its intended consumer.

**Fix** (`rtl/csr_block.v`, `rtl/tob_top.v`): new `seq_gap_amount` input
port on `csr_block.v`, connected to the already-existing top-level wire in
`tob_top.v`; a new `satadd` saturating add-by-amount function (alongside
the existing `satinc`, which every OTHER counter correctly still uses —
this is the one counter in the whole set that isn't a plain per-event tally
per FR-10's own text); `cnt_seq_gap`'s increment changed from
`satinc(cnt_seq_gap)` to `satadd(cnt_seq_gap, seq_gap_amount)`.

**Independently verified:**

- `tb/tb_top.v` itself: 35/35 counters match after the fix (was 1/35
  failing, `cnt_seq_gap` only, before it).
- **Mutation-tested at the integration level**: reverted the fix on a
  scratch `csr_block.v` — `tb/tb_top.v` caught it with the exact same
  failure signature originally found (`counter[addr=00d0] index 12: got 6,
  expected 23`).
- **`tb/tb_csr_block.v`'s own unit-level counter test (`pulse_one`/
  `read_cnt_chk`) had to be updated too** — it left the new
  `seq_gap_amount` port unconnected (X), which the mutation test surfaced
  immediately as `got xxxxxxxx`. Fixed by driving a **distinctive non-1
  amount (7)**, not 1, specifically so a mutant reverting to a flat +1
  cannot coincidentally pass — mutation-tested this unit test too (same
  mutant): caught with `got 00000001, expected 00000007`.
- Full `iverilog` regression (`scripts/run_sim.sh`), all per-module
  testbenches plus `tb_top.v` itself, passes clean.

**One harness bug found along the way, unrelated to any RTL**: an early
`$display` in `tb_top.v`'s Part B ("...not a failure)") contained the
literal substring "fail" inside the word "failure", which
`scripts/run_sim.sh`'s case-insensitive `grep -qi FAIL` log check flagged
as a false failure despite the test itself reporting `PASS`. Reworded to
avoid the substring — a reminder that a testbench's own informational
messages are part of its interface to the CI gate, not free-form text.

**`tb/tb_top.v` wired into `scripts/run_sim.sh`** (auto-generates
`tb/stimulus/tb_top_soak_*` via `sim/gen_top_soak_vectors.py` if missing,
same pattern as the existing S2 parser soak), so it runs on every `make
sim` / CI push from here on, not just this session.

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
