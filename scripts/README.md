# scripts/

`make_slides.py` (already here) generates `slides/FPGA_Tick_to_Trade.pptx` from
`project_explained_simple.md`.

Planned, not yet written (master spec §13):

```
build.tcl          headless Vivado build, non-project mode: `vivado -mode batch -source build.tcl`
build_hls4ml.py    hls4ml convert + build + export IP (ML collaborator's flow)
run_sim.sh          runs all tests, non-zero exit on failure
report.py           parses Vivado reports into the results/*.md tables
```

`CLAUDE.md`/`AGENTS.md` both warn not to assume these exist yet — check before invoking.
