# scripts/

`make_slides.py` (already here) generates `slides/FPGA_Tick_to_Trade.pptx` from
`project_explained_simple.md`.

`build.tcl` (already here) is the headless Vivado build, non-project mode:
`vivado -mode batch -source build.tcl` — invoked via `make synth`/`make bit`. It builds the
S0 skeleton today; grows as more of `rtl/` is wired into `tob_top.v`.

`run_sim.sh` (already here) runs every self-checking test in the repo — both Python
golden-model hand-cases, `sim/order_rx.py --selftest`, an RTL lint of `rtl/`, every
`tb/tb_<module>.v`, and (unless `RUN_SIM_FAST=1`) the S2 1,000,000-message parser soak —
exiting non-zero on any failure. Invoked via `make sim`; this is also what CI's
`golden-model-sim` job runs on every push (`.github/workflows/ci.yml`).

Planned, not yet written (master spec §13):

```
build_hls4ml.py    hls4ml convert + build + export IP (ML collaborator's flow) — needs S4 first
report.py           parses Vivado reports into the results/*.md tables — needs S10 first
```

`CLAUDE.md`/`AGENTS.md` both warn not to assume a file exists — check before invoking.
