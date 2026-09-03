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

The golden model in `sim/` still comes before the datapath modules proper (master spec §11.1:
written from the spec, not the RTL), then the stimulus generator, then those per-module
testbenches bottom-up.
