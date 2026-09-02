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

Only `tob_top.v` exists so far (the S0 Tier-A skeleton — clock/reset/key/LED only, no
datapath yet). Before adding the next module: define its interface (signals, widths,
handshake, latency) per `fpga_project_flow.md` Stage 4, lint it, and write its testbench in
`tb/` against the golden model in `sim/` before wiring it into `tob_top.v`. See
`docs/design_decisions.md` for the MAC-integration decisions (D1–D5) that shape
`eth_mac_if.v` and `common/mdio_ctrl.v` before you write them.
