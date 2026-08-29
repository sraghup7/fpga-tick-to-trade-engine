# AGENTS.md

## What this repo is
- **Spec-only, pre-implementation.** There is no `rtl/`, `sim/`, or Python code yet. Nothing to build, run, or test — do not assume a build/test/lint command exists.
- Git repository (initialized). The eventual code layout is defined in `fpga_tick_to_trade_master_spec.md` §13.

## Which file is authoritative
- `fpga_tick_to_trade_master_spec.md` is the **single source of truth** (merged master spec). It supersedes `fpga_top_of_book_engine_spec.md` and incorporates the (since removed) adverse-selection classifier spec.
- `fpga_top_of_book_engine_spec.md` is a **superseded** historical document. Do not edit it as authoritative; make changes in the master spec and keep its §0 reconciliation table consistent.
- `ml_engineer_brief.md` is a self-contained handoff for the ML collaborator (Python/hls4ml only, zero Verilog), mirroring §5–§11 of the master spec from the ML owner's side. Keep it in sync when the ML contract changes.

## Spec conventions (when editing the master doc)
- Requirements are numbered `FR-n` / `NFR-n`; every requirement must map to a test in §11.4. Adding a requirement without a test breaks the traceability model.
- Measured numbers (latency, utilization, timing) go in §12 tables, never asserted in prose.
- §0's reconciliation table records every deliberate change vs. the source specs — update it when you change behavior.

## Hard conventions for future code
- Hand-written RTL is **Verilog-2001 only** (no SystemVerilog) under `rtl/` (NFR-9); the sole exception is hls4ml/Vitis-generated IP.
- Target: Artix-7 `XC7A35T-2FGG484I`, 125 MHz single clock domain, Vivado 2023.x + Vitis HLS 2023.x.
