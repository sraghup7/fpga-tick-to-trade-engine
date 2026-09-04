# AGENTS.md

## What this repo is
- **Implementation in progress, milestones S0–S3/S5/S7/S8 done** (as of 2026-09-03). `rtl/`, `sim/`, `tb/`, `docs/contracts/` are populated; every landed module has a passing Icarus testbench, plus passing golden-model hand-cases and a passing 1M-message parser soak. `model/`/`hls4ml/` are still empty — S4/S6 (ML) and S9 (`latency_histogram.v`/`csr_block.v`)/S10 (`tb/tb_top.v`) haven't started. Check with `ls` before assuming a specific file exists. `make sim`/`make ml` are still stub echoes — run testbenches directly with `iverilog`/`vvp` (see `tb/README.md`); CI's regression job is still gated off pending `scripts/run_sim.sh`. The eventual full code layout is defined in `fpga_tick_to_trade_master_spec.md` §13.
- See `CLAUDE.md` for the full version of this guidance (project description, architecture diagram, toolchain, MCP servers) — this file mirrors it in short form; keep both in sync.

## Which file is authoritative
- `fpga_tick_to_trade_master_spec.md` is the **single source of truth** (merged master spec). It supersedes `fpga_top_of_book_engine_spec.md` and incorporates the (since removed) adverse-selection classifier spec.
- `fpga_top_of_book_engine_spec.md` is a **superseded** historical document. Do not edit it as authoritative; make changes in the master spec and keep its §0 reconciliation table consistent.
- `ml_engineer_brief.md` is a self-contained handoff for the ML collaborator (Python/hls4ml only, zero Verilog), mirroring §5–§11 of the master spec from the ML owner's side. Keep it in sync when the ML contract changes.
- `README.md` is the public-facing deliverable (architecture, wire format, decision rule, results); update it when master-spec user-facing facts change.
- `fpga_project_flow.md` is a general (non-project-specific) reference on the 9-stage FPGA methodology this repo follows.
- `PREREQUISITES.md` tracks toolchain versions/paths verified on the dev machine and open S0 items.

## Spec conventions (when editing the master doc)
- Requirements are numbered `FR-n` / `NFR-n`; every requirement must map to a test in §11.4. Adding a requirement without a test breaks the traceability model.
- Measured numbers (latency, utilization, timing) go in §12 tables, never asserted in prose.
- §0's reconciliation table records every deliberate change vs. the source specs — update it when you change behavior.

## Hard conventions for future code
- Hand-written RTL is **Verilog-2001 only** (no SystemVerilog) under `rtl/` (NFR-9); the sole exception is hls4ml/Vitis-generated IP.
- Target: Artix-7 `XC7A35T-2FGG484I`, 125 MHz single clock domain, Vivado 2023.x + Vitis HLS 2023.x.

## MCP servers available (registered globally in `~/.claude.json`)
- `vivado` (`mcp__vivado__*`) — Vivado 2024.2 (`D:\Vivado\2024.2`): synthesis/impl/bitstream, timing/utilization reports, XSim, XDC lint, `verilog_compile_check`. Interactive/diagnostic use only — the reproducible build stays in `scripts/build.tcl` (non-project mode), never the MCP session.
- `vitis` (`mcp__vitis__*`) — Vitis Unified IDE 2024.2 (`D:\Vitis\2024.2`), from [QingquanYao/vitis_mcp](https://github.com/QingquanYao/vitis_mcp) at `E:\Projects\vitis_mcp`. **Embedded-software / JTAG-debug tool, not HLS synthesis** — `create_platform`/`build_app`/`hw_program_fpga`/`hw_read_memory`, paired with Vivado MCP for bitstream→platform→app→JTAG. No dedicated HLS component/csim tools; the hls4ml→Vitis HLS IP export flow (`ml_engineer_brief.md` §8) is the ML collaborator's own CLI work, unrelated to this server. **Runs from its own venv** (`.venv`, `mcp==1.29.1`) — the shared Python 3.10 env has `vivado-mcp`'s `mcp==2.0.0`, which renamed the API this package imports (`fastmcp.FastMCP`→`mcpserver.MCPServer`); don't reinstall it into that shared env.
- `matlab` (`mcp__matlab__*`) — via `E:\Projects\MATLAB_MCP\bin\matlab-mcp-server-windows-x64.exe`. Not part of the documented toolchain; Python remains the spec's primary language for golden models/generators.
- `hound` (`mcp__hound__*`) — web research (`smart_search`/`smart_fetch`/`smart_crawl`); prefer it over ad hoc web fetches.

If a tool under one of these prefixes isn't in the active tool set, load it via `ToolSearch` (`select:mcp__vivado__...` etc.) before calling it.
