# Non-project-mode entry points. fpga_project_flow.md Stage 2 / master spec §13.
# `synth`/`bit` need Vivado; point VIVADO at your install if it's not on PATH.

VIVADO ?= D:/Vivado/2024.2/bin/vivado.bat

.PHONY: all sim synth bit ml clean

all: bit

synth bit:
	"$(VIVADO)" -mode batch -source scripts/build.tcl

sim:
	bash scripts/run_sim.sh

ml:
	@echo "Owned by the ML collaborator -- see ml_engineer_brief.md."

clean:
	rm -rf results/build *.jou *.log .Xil
