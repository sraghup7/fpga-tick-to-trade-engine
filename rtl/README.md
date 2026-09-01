# rtl/

Hand-written RTL, **Verilog-2001 only** (no SystemVerilog) — NFR-9. One module per pipeline
stage, per master spec §13 and §3 (block diagram):

```
tob_top.v              top-level integration
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
common/                shared modules (sync_2ff.v, counter_sat.v, ...)
```

Nothing here yet. Before adding a module: define its interface (signals, widths, handshake,
latency) per `fpga_project_flow.md` Stage 4, lint it, and write its testbench in `tb/` against
the golden model in `sim/` before wiring it into `tob_top.v`.
