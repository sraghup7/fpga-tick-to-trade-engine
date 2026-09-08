# results/

Published, measured results only — per master spec §12, never asserted in prose elsewhere.
This is what `README.md`'s results tables and `PREREQUISITES.md`'s verification log cite.

```
utilization.md        post-implementation resource utilization vs. §7.3 budget       -- populated (scripts/report.py)
timing.md              WNS/TNS at 125 MHz                                             -- populated (scripts/report.py)
latency_histogram.csv  measured tick-to-trade cycle counts (success criterion: max == min)  -- pending S11 (real hardware)
ml_metrics.md           classifier quality metrics (honest framing — see master spec §12.4) -- pending S4 (real trained model)
ila_captures/           on-chip logic analyzer capture exports, from hardware bring-up      -- pending S11
```

`utilization.md`/`timing.md` are generated from `results/build/*.rpt` (real Vivado
`report_utilization`/`report_timing_summary` output on the D40 gate-passing routed
build, `results/build/` itself gitignored per master spec §13) — run
`python scripts/report.py` to regenerate after a new build; do not hand-edit the
`.md` files. The other three genuinely have nothing yet: `latency_histogram.csv`
and `ila_captures/` need the board (S11, not yet attempted on physical hardware),
`ml_metrics.md` needs S4's real trained classifier (the current model is the
documented `w_i=1`/bias=0 placeholder).
