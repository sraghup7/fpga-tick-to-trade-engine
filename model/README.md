# model/

ML collaborator's side (Python/hls4ml only, zero Verilog) — see `ml_engineer_brief.md` for the
full contract. FPGA-side code never edits anything here directly; it only consumes the
exported IP behind `rtl/ml_classifier_wrap.v`.

```
train.py / train.ipynb   float logistic regression, then quantization (ml_engineer_brief.md §7.3)
model_config.json        feature/label/quantization config
weights.mem / bias.mem   quantized int8 weights, exported for RTL/testbench use
normalization.mem        per-feature normalization constants
golden_vectors.csv       exported vectors for hls4ml csim vs. ml_golden.py bit-exactness check
```

Nothing here yet.
