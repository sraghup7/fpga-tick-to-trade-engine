## Contract: implement FR-3's UDP destination-port match and FR-2's EtherType check — wire `cfg_udp_port`/`err_udp_port`/`err_ethertype` to something real

### Status: ready to hand off. Found by an external review (a second
Opus-model pass over the repo, given the master spec and pointed at the
RTL); independently confirmed by reading `rtl/tob_top.v` and the vendored
MAC's actual RX path (`rtl/vendor/alinx_mac/rx/{mac_rx,udp_rx}.v`) before
writing this contract.

### S0. The bug, in one sentence, and why it matters

`rtl/tob_top.v` ties `csr_block.v`'s `cfg_udp_port` output to nothing
(`.cfg_udp_port ()`, unconnected — register `0x40`, `UDP_PORT`, is fully
writable/readable but drives no logic) and ties `err_udp_port`/
`err_ethertype` (inputs to `csr_block.v`, feeding §10's counters) to
`1'b0` (permanently zero). Checked directly against the vendored MAC's
actual RX datapath: `udp_rx.v` receives and checksums the UDP payload but
never compares the destination port field against anything, and
`mac_rx.v` dispatches to the IP or ARP receive path based on an internal
`frame_type` register but never exposes "neither" as an error — it just
silently drops the frame (the same "frame suppression" behavior
`docs/design_decisions.md` D1/D5 already documented and partially
patched around for other signals). Net effect: **FR-3's UDP-port match is
entirely unimplemented** — any UDP datagram reaching the board's IP, on
ANY destination port, whose length is a multiple of 16, is parsed as
market data (and, per `docs/contracts/csr_ingress_separation.md`'s
findings, can also write CSRs including `CTRL.bit1`, kill-switch clear).
`err_udp_port` and `err_ethertype` are structurally unable to increment
as a direct consequence, which makes §11.5's "every error counter
incremented" coverage goal permanently unreachable for these two, and is
a security-relevant gap (an unfiltered UDP port on a device that can
receive kill-switch-clearing CSR writes) worth closing before S11 puts
this on a real network interface.

### S1. `rtl/vendor/alinx_mac/rx/udp_rx.v` — expose the destination port

**This is the D5 pattern**: a small, clearly-marked, additive patch to an
otherwise-vendored file (see this file's own existing `udp_checksum_error`
port and its comment — "(D5 patch, not in original ALINX source)... No
other behavior changed" — for the precedent and the exact commenting
style to match).

`udp_rx.v` streams the 8-byte UDP header (source port, dest port, length,
checksum — RFC 768 order) through `udp_rx_data`/`udp_rx_data_d0` during
its `REC_HEAD` state (`udp_rx_cnt` 0 through 7) but never captures the
destination-port bytes (header bytes 2-3) into a register of their own —
today they only ever pass through the running checksum accumulator. Add:

```verilog
// D-XX patch (not in original ALINX source): capture the UDP destination
// port (header bytes 2-3, RFC 768: src port 0-1 / dst port 2-3 / length
// 4-5 / checksum 6-7) so the engine can implement FR-3's port match --
// this module itself does no filtering, it only exposes the value.
reg [15:0] udp_rec_dest_port;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        udp_rec_dest_port <= 16'd0;
    else if (state == REC_HEAD && udp_rx_cnt == 16'd2)
        udp_rec_dest_port[15:8] <= udp_rx_data_d0;
    else if (state == REC_HEAD && udp_rx_cnt == 16'd3)
        udp_rec_dest_port[7:0]  <= udp_rx_data_d0;
end
```

**Trace the exact `udp_rx_cnt`-to-byte-offset alignment yourself before
committing to this** — the sketch above assumes `udp_rx_data_d0` at
`udp_rx_cnt == N` holds header byte `N-1` (one cycle of delay, matching
how the existing checksum accumulator consumes `udp_rx_data_d0` against
`udp_rx_cnt`) — confirm this against the checksum logic's own indexing
(`checksum_cnt`/`checksum_tmp*`, later in the file) rather than trusting
this contract's arithmetic blindly; get the byte alignment right by
cross-checking against a KNOWN-good field this file already computes
correctly (`udp_data_length`, captured from `upper_layer_data_length`
rather than parsed here, won't help directly — but the checksum
computation's own byte indexing, which the file already gets right today,
is the thing to mirror). Add `udp_rec_dest_port` to the port list as a new
16-bit output.

Add a directed testbench case (new or extending whatever
`tb_eth_mac_if_rx.v` / a vendored-MAC-level test already drives this
module — check `tb/` for existing coverage of `udp_rx.v`, it is exercised
indirectly by `tb_eth_mac_if_rx.v` per D1/D5's own history) that feeds a
UDP frame with a KNOWN destination port and asserts `udp_rec_dest_port`
holds that exact value at/after `udp_rec_data_valid` — this is the
highest-value single check in this whole contract, since a byte-order or
off-by-one-cycle mistake here would make every downstream comparison
silently wrong in a way nothing else would catch.

### S2. `rtl/vendor/alinx_mac/mac_top.v` (or wherever `udp_rx`'s ports
surface today) — thread `udp_rec_dest_port` to the top

`mac_top.v` already threads `udp_rec_data_valid`/`udp_rec_data_length`/
`udp_rec_ram_rdata` from `udp_rx.v` up to its own port list (confirm the
exact port names by reading `mac_top.v`'s `udp_rx` instantiation and its
own port list side by side). Add `udp_rec_dest_port` the same way — pure
plumbing, no new logic in this file.

### S3. `rtl/eth_mac_if.v` — thread it further, to `frame_classifier.v`

`eth_mac_if.v` (D1's adapter module) already converts the vendored MAC's
whole-frame-buffered RX interface into the byte-stream shape the rest of
the datapath expects, and already exposes some of the vendored MAC's
signals as its own outputs (check its current port list for the pattern
used for `udp_checksum_error`, which made this same D1→D5 journey).
Expose `udp_rec_dest_port` as a new output the same way.

### S4. `rtl/frame_classifier.v` — implement FR-2's EtherType check and FR-3's port match

**This is the actual filtering logic** — the one place FR-2/FR-3 says the
check belongs (§6.1: "`LINK_MODE=1`: accept EtherType `0x0800`, IHL=5,
valid IPv4 header checksum, protocol 17, UDP port = `cfg_udp_port`. Any
failure discards and increments the matching counter."). Per D1's own
note, `frame_classifier.v` currently does NOT re-parse EtherType/IPv4/UDP
port for `LINK_MODE=1` because `udp_rx.v` already validates
framing/checksum before ever asserting `udp_rec_data_valid` — that
reasoning still holds for everything EXCEPT the port match, which
`udp_rx.v` genuinely never checks (S0). Add a new comparison, gated the
same way this module already gates on `udp_rec_data_valid`/
`udp_checksum_error` etc.:

```verilog
// FR-3: UDP destination port must match cfg_udp_port. udp_rx.v (S1 patch)
// exposes the raw value; the actual match/discard decision belongs here,
// same as every other LINK_MODE=1 framing check this module already owns.
wire port_match = (udp_rec_dest_port == cfg_udp_port);
```

Wire a new `cfg_udp_port` input port onto `frame_classifier.v` (it doesn't
have one today) and a new `err_udp_port` output pulse, following the
exact same one-shot/discard-the-frame shape this module already uses for
its other `LINK_MODE=1` checks (`err_frame_len` is the closest existing
precedent — read how that one currently gates frame acceptance and match
its timing/pulse discipline exactly, including whether the check happens
before or after `md_parser.v` starts consuming the frame — get this
wrong and a partially-parsed frame could leak through). A port mismatch
must discard the ENTIRE frame (no messages within it reach `md_parser.v`)
and increment `err_udp_port` exactly once per mismatched frame, mirroring
FR-5's existing `err_frame_len` discard-and-recover behavior (return to
idle cleanly before the next frame, per FR-5's own wording, which
generalizes to every frame-level discard in this module by the existing
convention — confirm this by reading how `err_frame_len` already does it).

### S5. FR-2 (EtherType), `rtl/vendor/alinx_mac/rx/mac_rx.v` — `err_ethertype`

Separate from S1-S4 (different signal, different module boundary), same
category of gap: `mac_rx.v`'s internal `frame_type` register (line ~40,
`reg [15:0] frame_type`) already exists and is already compared against
`16'h0800`/`16'h0806` (IP/ARP) at its dispatch point (lines ~107/169/179)
— frames matching neither are silently never requested
(`ip_rx_req`/`arp_rx_req` both stay low), the same "frame suppression"
class of gap D1/D5 already found and partially patched for other signals
in this exact file family. Add a new one-cycle pulse output,
`err_ethertype`, following the D5 pattern precisely: fires exactly once
per fully-received frame whose `frame_type` is neither `16'h0800` nor
`16'h0806`, timed at the same point the existing dispatch decision is
already made (do not re-derive the comparison independently elsewhere —
compute it from the SAME `frame_type` value and at the SAME point in the
state machine this file already uses to decide `ip_rx_req`/`arp_rx_req`,
so there is exactly one source of truth for "what ethertype was this
frame" inside this module). Thread it up through `mac_top.v` →
`eth_mac_if.v` → `frame_classifier.v` (same three-file plumbing chain as
S1-S3) and wire the final `err_ethertype` count-increment pulse at
`frame_classifier.v`'s own boundary, replacing `tob_top.v`'s current
`.err_ethertype (1'b0)` tie-off.

### S6. `rtl/tob_top.v` — the two tie-off fixes

```verilog
// was: .cfg_udp_port (),
.cfg_udp_port (cfg_udp_port),   // now driven from csr_block.v to frame_classifier.v

// was: .err_ethertype (1'b0),
.err_ethertype (fc_err_ethertype),   // from frame_classifier.v (S5's plumbing)

// was: .err_udp_port (1'b0),
.err_udp_port (fc_err_udp_port),     // from frame_classifier.v (S4)
```

Match this repo's existing naming convention for `frame_classifier.v`'s
other error outputs already wired at this instantiation (`fc_err_frame_len`
is the pattern to follow — same prefix, same wire-declaration style,
declared alongside it near the top of `tob_top.v`).

### S7. Explicitly out of scope

- IHL=5 and IPv4-header-checksum validation (also part of FR-3's full
  text) — already correctly handled today via `udp_checksum_error`/
  `ip_addr_check_error` (D5's own prior work); this contract does not
  touch those paths.
- `LINK_MODE=0` (raw EtherType `0x88B5` mode) — deferred per D3, not part
  of the current bring-up default; do not add any raw-mode logic here.
- `csr_block.v` — no changes; `cfg_udp_port`/`err_udp_port`'s register-map
  addresses and read/write behavior already work correctly, they're
  simply unconsumed today. This contract only wires the consumer.
- Anything in `md_parser.v`, `symbol_filter.v`, `seq_monitor.v` — this
  fix operates entirely at the frame level, upstream of all three;
  none of them need to change.
- `docs/contracts/csr_ingress_separation.md` — a separate, independent
  contract (different files: `md_parser.v`/`seq_monitor.v`/
  `csr_block.v`'s counter wiring vs. this contract's
  `udp_rx.v`/`mac_rx.v`/`mac_top.v`/`eth_mac_if.v`/`frame_classifier.v`
  chain). Safe to implement in either order or in parallel — flag a
  conflict in your report if you find one, but none is expected.

### S8. Acceptance criteria

**Yours to verify (iverilog):**
- Every touched file compiles under `iverilog -g2001 -Wall`, no new
  warnings, no inferred latches. Note: files under `rtl/vendor/alinx_mac/`
  are vendored but ARE part of this project's Verilog-2001 lint/compile
  gate (`docs/design_decisions.md`'s existing D5 precedent already
  modifies this exact file family) — do not treat "it's vendored" as a
  reason to skip verification rigor.
- New/extended directed tests: (a) `udp_rx.v`-level, per S1, proving
  `udp_rec_dest_port` is byte-exact and correctly timed for a known
  frame; (b) `frame_classifier.v`-level, proving a UDP frame to the
  CONFIGURED port passes through unchanged (regression: every existing
  `LINK_MODE=1` test must still pass with the port check now active,
  since they presumably already use the default port) and a frame to a
  DIFFERENT port is discarded whole with `err_udp_port` incrementing
  exactly once, no message from it ever reaching `md_parser.v`; (c) an
  `err_ethertype` case — a frame type outside `{0x0800, 0x0806}` is
  silently dropped today (confirm this still holds) AND now increments
  `err_ethertype` exactly once.
- `tb_tob_top`/`tb_top`: re-run as-is first — every existing test sends
  traffic on the default port (`60000`, matching `cfg_udp_port`'s reset
  value), so this should be a pure regression check, not require new
  vectors, UNLESS your S4 timing/gating choice changes something about
  frame-acceptance latency, in which case say so explicitly and show
  exactly what changed and why it's still correct.
- Full `bash scripts/run_sim.sh` passes.
- `git diff` on every file not listed in S1-S6 (in particular
  `md_parser.v`, `symbol_filter.v`, `seq_monitor.v`, `csr_block.v`, and
  every risk/ML/signal module) is empty.
- In your report: state explicitly which `udp_rx_cnt` values you
  confirmed correspond to UDP header bytes 2-3 and HOW you confirmed it
  (not just "I believe" — cross-referenced against the checksum
  accumulator's own indexing, or a simulation waveform showing the
  captured value against a hand-encoded test frame) — this is the one
  place in the whole contract most likely to be silently wrong in a way
  that still compiles and even passes a lazily-written test (e.g. a test
  that only checks the port match fires/doesn't fire for the SAME port
  used to derive the implementation, rather than an independently
  chosen known value).

**Mine to verify (independent re-check per this project's established
workflow):** re-diff every changed file, re-compile and re-run every
testbench myself, and independently construct at least one UDP frame
with a hand-picked, non-default destination port to confirm the reject
path end to end.
