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

Nothing here yet — the golden model in `sim/` comes first (master spec §11.1: written from the
spec, not the RTL), then the stimulus generator, then per-module testbenches bottom-up.
