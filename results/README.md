# results/

Published, measured results only — per master spec §12, never asserted in prose elsewhere.
This is what `README.md`'s results tables and `PREREQUISITES.md`'s verification log cite.

```
utilization.md        post-implementation resource utilization vs. §7.3 budget
timing.md              WNS/TNS at 125 MHz
latency_histogram.csv  measured tick-to-trade cycle counts (success criterion: max == min)
ml_metrics.md           classifier quality metrics (honest framing — see master spec §12.4)
ila_captures/           on-chip logic analyzer capture exports, from hardware bring-up
```

Nothing here yet — this fills in during Stage 6 onward (`fpga_project_flow.md`), not before.
