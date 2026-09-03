# rtl/

Hand-written RTL, **Verilog-2001 only** (no SystemVerilog) — NFR-9. One module per pipeline
stage, per master spec §13 and §3 (block diagram):

```
tob_top.v              top-level integration (S0 skeleton in place; grows incrementally)
eth_mac_if.v           adapts vendor/alinx_mac's byte-push/RAM boundary to a byte-stream
frame_classifier.v     EtherType / IPv4 / UDP classification
md_parser.v            byte-serial market-data parser
symbol_filter.v        4-entry symbol CAM
seq_monitor.v          sequence-gap detection, staleness
tob_engine.v           top-of-book state (best bid/ask)
feature_extractor.v    F0-F7 feature computation
feature_normalizer.v   feature -> int8
ml_classifier_wrap.v   wraps the hls4ml-generated IP; never edit the IP directly
ml_policy.v            hysteresis on the classifier verdict
signal_engine.v        spread + imbalance decision rule
risk_engine.v           9 pre-trade risk gates (see master spec §8)
order_builder.v        order intent -> output frame
latency_histogram.v    BRAM, 64 buckets
csr_block.v            config registers + counters
vendor/alinx_mac/      ALINX reference MAC, vendored per docs/design_decisions.md D1 — do not
                       hand-edit except the two status ports added per D5
common/                shared modules (sync_2ff.v, counter_sat.v, mdio_ctrl.v, ...)
```

`tob_top.v` (S0 Tier-A skeleton), `eth_mac_if.v`, `vendor/alinx_mac/` (D1, D5), and
`common/{sync_2ff,counter_sat,mdio_ctrl}.v` exist. `eth_mac_if.v` is tested two ways —
`tb/tb_eth_mac_if_rx.v` against a mocked RAM boundary, `tb/tb_eth_mac_if_tx.v` against the
*real* vendored `mac_top.v` (checking the actual transmitted UDP checksum against an
independent RFC 768 computation) — see `docs/design_decisions.md` D10 for why the TX side
needed that and not the RX side. `tb/sim_models/xilinx_ip_sim_models.v` provides simulation
stand-ins for three Xilinx IP cores the vendor MAC depends on that have no real sim model
available locally — simulation-only, never referenced by `scripts/build.tcl` (see D8: the
real IP cores need regenerating in Vivado before any synthesis that touches `vendor/alinx_mac/`).
`eth_mac_if.v` also exposes `frame_start`/`rx_len` (D11) so `frame_classifier.v` can gate a
frame's byte stream before any of its bytes arrive.

Not yet written: `frame_classifier.v` through `csr_block.v`. Before adding the next one:
define its interface (signals, widths, handshake, latency) per `fpga_project_flow.md` Stage 4,
lint it, and write its testbench in `tb/` against the golden model in `sim/` before wiring it
into `tob_top.v`. `docs/design_decisions.md` D1–D10 record the MAC-integration decisions
already made.
