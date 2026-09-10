# Non-project-mode entry points. fpga_project_flow.md Stage 2 / master spec §13.
# `synth`/`bit` need Vivado; point VIVADO at your install if it's not on PATH.

VIVADO ?= D:/Vivado/2024.2/bin/vivado.bat

.PHONY: all sim synth bit ml clean

all: bit

synth bit:
	"$(VIVADO)" -mode batch -source scripts/build.tcl

sim:
	bash scripts/run_sim.sh

# NOTE (D53, docs/design_decisions.md): classifier weights are elaboration-
# time constants baked into rtl/ml_classifier_wrap.v via $readmemh, and
# different weight VALUES synthesize to different shift-add/CARRY4
# structures -- so a retrain can change synthesis timing with no RTL change
# at all. After running `make ml`, re-run `make synth` and re-check
# results/build/timing_summary.rpt before trusting any existing bitstream;
# this is NOT automated into this target (training/export only).
ml:
	cd model && python train.py
	python scripts/gen_ml_bit_exact_vectors.py

clean:
	rm -rf results/build *.jou *.log .Xil
