# tb/

Self-checking testbenches, one per RTL module plus a top-level integration testbench, per
master spec §11.3 and `fpga_project_flow.md` Stage 3-4.

```
tb_top.v          full-pipeline integration testbench, checks against sim/golden_model.py output
tb_<module>.v      one per rtl/ module, verified before that module is wired into tob_top.v
stimulus/          generated test vectors (parametric: corruption type + location, seeded)
```

Icarus Verilog (`iverilog`/`vvp`) is the fast lint+sim loop for plain Verilog-2001 testbenches;
XSim is for anything needing SVA. See `PREREQUISITES.md` for the known Windows 11 24H2
`NoDefaultCurrentDirectoryInExePath` issue that breaks XSim's `launch_simulation` until fixed.

`tb_mdio_ctrl.v`, `tb_sync_2ff.v`, `tb_counter_sat.v`, `tb_eth_mac_if_rx.v`, and
`tb_eth_mac_if_tx.v` exist (per-module testbenches for the common/ utilities and the MAC
adapter, ahead of the datapath modules since those had to land first per D1-D10). `sim_models/`
holds simulation-only stand-ins for Xilinx IP cores the vendored MAC depends on — never
synthesized, see its own header comment and docs/design_decisions.md D10.
`tb_frame_classifier.v` covers FR-4/FR-5 (T01, T02, T05, plus the FR-4 upper-bound case)
against `rtl/frame_classifier.v`.
`tb_md_parser.v` covers FR-4/FR-8/FR-9 (T01, T02, T06) against `rtl/md_parser.v`.
`tb_parser_soak.v` is the S2 milestone's "1M-message parse, zero loss" gate: chains
frame_classifier.v -> md_parser.v over 1,000,000 generated messages
(sim/gen_soak_vectors.py), checking exact message-count conservation and
spot-checked field correctness. **Passing.**

`tb_symbol_filter.v`, `tb_seq_monitor.v`, `tb_tob_engine.v` (S3, FR-7/10-19), and
`tb_feature_extractor.v`/`tb_feature_normalizer.v` (S3, FR-20-25 against `sim/feature_golden.py`)
now exist and pass. `tb_signal_engine.v` (S5, FR-35-40, T13/T14 incl. exact thresholds — D15's
wide-precision-shift fix is what makes FR-37's conflict path genuinely unreachable, not just
untested) and `tb_risk_engine.v` (S7, all nine gates incl. the D16-D18 golden-model/RTL fixes)
pass. `tb_order_builder.v` (S8, FR-49-52) passes.

`tb_top.v` (the full-pipeline integration testbench listed above) is **not written yet** — it
needs the ML path (S6) to exist first, since the risk engine's gate `0x09` is currently
untestable end-to-end without `ml_classifier_wrap.v`/`ml_policy.v` in the loop. Per-module
testbenches are the only coverage until then.

The golden model in `sim/` still comes before the datapath modules proper (master spec §11.1:
written from the spec, not the RTL), then the stimulus generator, then those per-module
testbenches bottom-up.
