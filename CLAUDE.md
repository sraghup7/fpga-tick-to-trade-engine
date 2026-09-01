# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**Spec-only, pre-implementation** (as of this writing). There is no `rtl/`, `sim/`, `tb/`, or `model/` yet, and no build/test/lint command exists — do not assume one does, and do not invent Makefile targets or scripts that aren't there. The repo currently holds the specification, reference PDFs, and planning docs; RTL and Python tooling land on `develop` as implementation proceeds. Check current state with `ls` before assuming a directory from the planned layout below exists.

`fpga-tick-to-trade-engine`: a pipelined FPGA datapath (Artix-7 XC7A35T-2FGG484I, ALINX AX7035B board) that receives a synthetic Gigabit-Ethernet market-data feed, maintains top-of-book state, runs a quantized ML classifier as an in-path risk gate, and emits a simulated order at a fixed, measured tick-to-trade latency — verified bit-exact against a Python golden model. Simulated trading only; never connects to a real exchange or handles money.

## Authoritative documents — read in this order

1. **`fpga_tick_to_trade_master_spec.md`** — the single source of truth (v2.0, merged master spec). Design, requirements (`FR-n`/`NFR-n`), risk engine, register map, verification plan, results tables, repo layout (§13), milestones. **All design decisions get recorded here; don't maintain a second parallel spec.**
2. **`ml_engineer_brief.md`** — self-contained handoff for the ML/hls4ml side (Python/hls4ml only, zero Verilog). Keep in sync with the master spec §5–§11 when the ML contract changes.
3. **`AGENTS.md`** — short-form conventions (below); read it directly, it's terse.
4. **`fpga_top_of_book_engine_spec.md`** — **superseded historical document.** Do not edit as authoritative; changes go in the master spec, keeping its §0 reconciliation table consistent.
5. **`fpga_project_flow.md`** — general reference on the 9-stage FPGA project methodology (spec → environment → verification → RTL → integration → constraints/synth → implementation/timing → bring-up → release). Not project-specific, but explains *why* the repo is organized the way §13 of the master spec specifies (golden model before RTL, non-project-mode Vivado builds, lint→sim→synth→impl loop ordering, etc).
6. **`PREREQUISITES.md`** — toolchain versions/paths actually verified on the dev machine (Vivado/Vitis HLS 2024.2, Python 3.11.15, Icarus 12.0, target part `xc7a35tfgg484-2`). Has the open items list (§6) that S0 needs to resolve.

## Spec conventions (when editing the master doc)

- Requirements are numbered `FR-n` / `NFR-n`; every requirement must map to a test in master-spec §11.4. Adding a requirement without a corresponding test breaks the traceability model.
- Measured numbers (latency, utilization, timing) go in master-spec §12 tables only — never assert measured numbers in prose.
- Master-spec §0's reconciliation table records every deliberate change vs. superseded source specs — update it when behavior changes.

## Hard conventions for future code

- Hand-written RTL is **Verilog-2001 only** (no SystemVerilog) under `rtl/` (NFR-9); the sole exception is hls4ml/Vitis-generated IP.
- Target device: Artix-7 `XC7A35T-2FGG484I` (ALINX AX7035B board), single 125 MHz clock domain, Vivado 2023.x+ / Vitis HLS 2023.x+ (2024.2 verified locally, see `PREREQUISITES.md`).
- Prices are integer ticks, never floats — exact comparison, no float arithmetic anywhere (RTL, golden model, or labeler). Integer mid is `(bid+ask)>>1` everywhere.
- ML is a **risk gate** (`0x09`), not the trading signal: `z = b + Σ w_i·x_i`, weights `int8`, accumulator `int32`. It can only block/reduce an order; it never overrides the kill switch or the other 8 deterministic risk gates, and deterministic gates always dominate the reported reject reason.
- The two datapath halves (deterministic signal path, ~2 cycles; ML path, ~7–10 cycles) run in parallel and are re-aligned via a fixed-depth register before the risk engine, so tick-to-trade stays a fixed cycle count even with ML in the path — don't break that invariant when touching `signal_engine`/`ml_*`/the alignment stage.
- Golden models are written **from the spec**, not from the RTL — a model derived from the RTL only confirms the RTL matches itself.

## Planned repository layout (master spec §13)

Authored/versioned vs. generated/ignored is the organizing rule — **if the build can regenerate it, it does not go in version control** (checkpoints, bitstreams, reports, logs, waveforms, the Vivado project file, the block-design binary blob are all ignored; `.xci` IP config is the one generated-but-versioned exception).

```
rtl/            one Verilog-2001 module per file (tob_top, frame_classifier, md_parser,
                symbol_filter, seq_monitor, tob_engine, feature_extractor/normalizer,
                ml_classifier_wrap, ml_policy, signal_engine, risk_engine, order_builder,
                latency_histogram, csr_block, common/)
hls4ml/         generated Vitis HLS project (gitignored, rebuilt by scripts/build_hls4ml.py)
tb/             self-checking testbenches (tb_top.v, tb_<module>.v, stimulus/)
sim/            golden_model.py, ml_golden.py, feed_gen.py, order_rx.py, compare.py
model/          train.py, model_config.json, weights.mem/bias.mem, normalization.mem,
                golden_vectors.csv — ML collaborator's side, python/hls4ml only
constraints/    tob_pins.xdc, tob_timing.xdc
scripts/        build.tcl (headless Vivado, non-project mode), build_hls4ml.py,
                run_sim.sh, report.py
results/        utilization.md, timing.md, latency_histogram.csv, ml_metrics.md, ila_captures/
docs/           block_diagram.svg, latency_budget.md, fixed_point_contract.md,
                hls4ml_flow.md, design_decisions.md
```

Planned build entry points (not present yet — check before using): `make sim`, `make synth`, `make bit`, `make ml`, `make all`. The primary Vivado build path is **non-project mode**: one reviewable `build.tcl` run via `vivado -mode batch -source build.tcl` (see `fpga_project_flow.md` Stage 2), not a GUI-managed `.xpr`.

## Toolchain (verified on this machine — see `PREREQUISITES.md` for full detail)

| Tool | Version | Path |
| :-- | :-- | :-- |
| Vivado | 2024.2 | `D:\Vivado\2024.2` |
| Vitis HLS | 2024.2 | `D:\Vitis\2024.2` |
| Python | 3.11.15 | `python` (PATH) |
| Icarus Verilog | 12.0 (devel) | `C:\iverilog\bin` — plain Verilog-2001 only, no SVA/SystemVerilog |
| GTKWave | — | `C:\iverilog\gtkwave\bin` |

GNU Make is **not** currently installed (`PREREQUISITES.md` §2.1) — don't assume `make` works until confirmed. `vivado-mcp` is the chosen Vivado↔AI bridge for interactive timing/ILA/hierarchy work; the reproducible build itself stays in `build.tcl`, not the MCP session.

## MCP servers available in this project

Registered globally in `~/.claude.json` (so any Claude Code session has them, not just this repo):

| Server | Tool prefix | Backs | Notes |
| :-- | :-- | :-- | :-- |
| `vivado` | `mcp__vivado__*` | Vivado 2024.2 (`D:\Vivado\2024.2`) | synthesis/impl/bitstream, timing/utilization reports, XSim, XDC lint, `verilog_compile_check` (auto-discovers Icarus). Interactive/diagnostic use only — the reproducible build stays in `scripts/build.tcl` (non-project mode), never the MCP session. |
| `vitis` | `mcp__vitis__*` | Vitis Unified IDE 2024.2 (`D:\Vitis\2024.2`) | **Embedded-software / JTAG-debug tool, not an HLS-synthesis tool** — `create_platform`/`build_app`/`hw_program_fpga`/`hw_read_memory` etc., paired with Vivado MCP for bitstream→platform→app→JTAG. No dedicated HLS component/csim tools; its `run_python_script` can reach the Vitis HLS component Python API if ever needed, but that's not a first-class supported path. The hls4ml→Vitis HLS IP export flow (`ml_engineer_brief.md` §8) is the ML collaborator's own CLI work, unrelated to this server. Installed from [QingquanYao/vitis_mcp](https://github.com/QingquanYao/vitis_mcp) at `E:\Projects\vitis_mcp`. **Runs from its own venv** (`E:\Projects\vitis_mcp\.venv`, `mcp==1.29.1`) — the plain Python 3.10 site-packages has `vivado-mcp`'s `mcp==2.0.0`, which renamed `mcp.server.fastmcp.FastMCP`→`mcp.server.mcpserver.MCPServer` and breaks this package's older-API import. Don't `pip install -e .` this into the shared Python 3.10 env again; use the venv. |
| `matlab` | `mcp__matlab__*` | MATLAB (via `E:\Projects\MATLAB_MCP\bin\matlab-mcp-server-windows-x64.exe`) | Not part of the documented toolchain (`PREREQUISITES.md` has no MATLAB entry) — available for ad hoc numeric work (e.g. cycle-budget arithmetic, fixed-point prototyping) if useful, but Python is the spec's primary language for golden models/generators. |
| `hound` | `mcp__hound__*` | — | Web research (`smart_search`/`smart_fetch`/`smart_crawl`) — see the user's global CLAUDE.md; use it instead of ad hoc web fetches. |

If a tool under one of these prefixes isn't listed in the active tool set, load it via `ToolSearch` (`select:mcp__vivado__...` etc.) before calling it — see the deferred-tools system reminder.

## Repo quirk

`docs/refs/AX7035/` is a **nested git repository** (vendor reference project, not a submodule) checked in for datasheets/example code. Don't run repo-wide git operations expecting it to behave like a normal tracked directory, and don't treat its presence as something to "fix."
