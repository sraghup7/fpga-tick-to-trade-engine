# sim/

Python golden models and verification tooling — the reference that `tb/` testbenches check
RTL against. Written **from the spec**, not derived from the RTL (master spec §11.1;
`fpga_project_flow.md` Stage 3): a model derived from the RTL can only confirm the RTL matches
itself. Bit-exact fixed-point arithmetic throughout — no floats standing in for integer ticks.

```
golden_model.py    reference implementation of the full datapath (parse -> book -> signal -> risk -> order)
ml_golden.py        fixed-point reference for the ML classifier (must agree bit-exactly with
                    hls4ml's csim output on every exported vector — ml_engineer_brief.md §8.3)
feed_gen.py         parametric stimulus generator (corruption type + location, seeded)
order_rx.py          host-side order-stream receiver / latency log parser
compare.py           RTL vs. golden-model output diff, first-divergence reporting
```

Nothing here yet. This is Stage 3 of `fpga_project_flow.md` and comes **before** RTL.
