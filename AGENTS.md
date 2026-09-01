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

## MCP servers available (registered globally in `~/.claude.json`)
- `vivado` (`mcp__vivado__*`) — Vivado 2024.2 (`D:\Vivado\2024.2`): synthesis/impl/bitstream, timing/utilization reports, XSim, XDC lint, `verilog_compile_check`. Interactive/diagnostic use only — the reproducible build stays in `scripts/build.tcl` (non-project mode), never the MCP session.
- `vitis` (`mcp__vitis__*`) — Vitis Unified IDE 2024.2 (`D:\Vitis\2024.2`), from [QingquanYao/vitis_mcp](https://github.com/QingquanYao/vitis_mcp) at `E:\Projects\vitis_mcp`. **Embedded-software / JTAG-debug tool, not HLS synthesis** — `create_platform`/`build_app`/`hw_program_fpga`/`hw_read_memory`, paired with Vivado MCP for bitstream→platform→app→JTAG. No dedicated HLS component/csim tools; the hls4ml→Vitis HLS IP export flow (`ml_engineer_brief.md` §8) is the ML collaborator's own CLI work, unrelated to this server. **Runs from its own venv** (`.venv`, `mcp==1.29.1`) — the shared Python 3.10 env has `vivado-mcp`'s `mcp==2.0.0`, which renamed the API this package imports (`fastmcp.FastMCP`→`mcpserver.MCPServer`); don't reinstall it into that shared env.
- `matlab` (`mcp__matlab__*`) — via `E:\Projects\MATLAB_MCP\bin\matlab-mcp-server-windows-x64.exe`. Not part of the documented toolchain; Python remains the spec's primary language for golden models/generators.
- `hound` (`mcp__hound__*`) — web research (`smart_search`/`smart_fetch`/`smart_crawl`); prefer it over ad hoc web fetches.

If a tool under one of these prefixes isn't in the active tool set, load it via `ToolSearch` (`select:mcp__vivado__...` etc.) before calling it.
