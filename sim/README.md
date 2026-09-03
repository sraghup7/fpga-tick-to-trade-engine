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

`golden_model.py` and `feed_gen.py` exist (S1, FPGA side). `sim/test_golden_model_handcase.py`
is the S1 milestone gate itself -- a hand-computed 20-message case, run with
`python sim/test_golden_model_handcase.py`. Scope: the full deterministic path (parse -> filter
-> seq monitor -> book -> signal -> risk gates 0x01-0x08); gate 0x09 (ML) is an injectable
`adverse_risk` argument, not computed here -- feature extraction and the classifier are
`ml_golden.py`'s side (ml_engineer_brief.md's division-of-responsibility table). `feed_gen.py`
implements 6 of S11.2's 7 scenarios; `adverse` is intentionally not implemented yet -- it needs
the label definition (S5.2) frozen jointly with the ML collaborator first, which is itself
part of S1's own gate.

`gen_soak_vectors.py` exists (S2) -- generates tb/tb_parser_soak.v's
1,000,000-message stimulus by reusing feed_gen.py's "normal" scenario
unmodified.

`ml_golden.py`, `train.py`, `order_rx.py`, `compare.py` are not written yet.
