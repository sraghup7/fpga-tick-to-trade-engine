# scripts/

`make_slides.py` (already here) generates `slides/FPGA_Tick_to_Trade.pptx` from
`project_explained_simple.md`.

`build.tcl` (already here) is the headless Vivado build, non-project mode:
`vivado -mode batch -source build.tcl` — invoked via `make synth`/`make bit`. It builds the
S0 skeleton today; grows as more of `rtl/` is wired into `tob_top.v`.

Planned, not yet written (master spec §13):

```
build_hls4ml.py    hls4ml convert + build + export IP (ML collaborator's flow) — needs S4 first
run_sim.sh          runs all tests, non-zero exit on failure — blocks CI's golden-model-sim job
report.py           parses Vivado reports into the results/*.md tables
```

`CLAUDE.md`/`AGENTS.md` both warn not to assume a file exists — check before invoking. Until
`run_sim.sh` exists, run each testbench directly with `iverilog`/`vvp` (see `tb/README.md`);
`make sim` is still a stub.
