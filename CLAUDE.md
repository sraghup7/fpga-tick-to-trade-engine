# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**Spec-only, pre-implementation** (as of this writing). There is no `rtl/`, `sim/`, `tb/`, `model/`, or `hls4ml/` yet, and no build/test/lint tooling exists — do not assume any command (`make`, `pytest`, Vivado, Vitis HLS, etc.) works, and do not invent Makefile targets or scripts that aren't there. Check current state with `ls` before assuming a directory from the planned layout below exists. The repo currently holds the specification, reference PDFs, and planning docs; RTL and Python tooling land on `develop` as implementation proceeds.

`fpga-tick-to-trade-engine`: a pipelined FPGA datapath (Artix-7 XC7A35T-2FGG484I, ALINX AX7035B board, Micrel KSZ9031RNX PHY) that receives a synthetic Gigabit-Ethernet market-data feed, parses and filters it, maintains top-of-book state, extracts fixed-point features, runs a quantized (hls4ml-generated) linear classifier that estimates adverse-selection risk, and gates the resulting order intent through nine non-bypassable pre-trade risk checks (including the ML verdict) before emitting a simulated order — all at a fixed, measured tick-to-trade cycle count, verified bit-exact against a Python golden model. Simulated trading only; never connects to a real exchange or handles money.

## Authoritative documents — read in this order

1. **`fpga_tick_to_trade_master_spec.md`** — the single source of truth (v2.0, merged master spec). Design, requirements (`FR-n`/`NFR-n`), risk engine, register map, counters, verification plan, results tables, repo layout (§13), milestones. **All design decisions get recorded here; don't maintain a second parallel spec.** §0 has a reconciliation table against the documents it superseded.
2. **`ml_engineer_brief.md`** — self-contained handoff for the ML/hls4ml collaborator (Python + hls4ml only, zero Verilog). Mirrors §5–§11 of the master spec from the ML side. Keep it in sync whenever the ML contract (features, label, quantization, IP interface) changes in the master spec.
3. **`README.md`** — the public-facing deliverable (architecture diagram, wire format, decision rule, risk table, reproduction commands, results, limitations). Update it when the master spec's user-facing facts change; it's explicitly listed as a deliverable in §13.
4. **`AGENTS.md`** — short-form conventions mirroring this file, for agents that read that name instead; read it directly, it's terse. Keep it in sync with this file.
5. **`fpga_top_of_book_engine_spec.md`** — **superseded historical document.** Never edit it as authoritative; if a change affects material also described here, make the change in the master spec and update its §0 reconciliation table instead.
6. **`fpga_project_flow.md`** — general reference on the 9-stage FPGA project methodology (spec → environment → verification → RTL → integration → constraints/synth → implementation/timing → bring-up → release). Not project-specific, but explains *why* the repo is organized the way §13 of the master spec specifies (golden model before RTL, non-project-mode Vivado builds, lint→sim→synth→impl loop ordering, etc).
7. **`PREREQUISITES.md`** — toolchain versions/paths actually verified on the dev machine (Vivado/Vitis HLS 2024.2, Python 3.11.15, Icarus 12.0, target part `xc7a35tfgg484-2`). Has the open items list that S0 needs to resolve, and a running verification log.

If a fact needs to change, change it at its source document and let the others reference it.

## Spec conventions (when editing the master doc)

- Requirements are numbered `FR-n` (functional, §6) / `NFR-n` (non-functional, §7); **every requirement must map to at least one test in §11.4** — adding a requirement without a corresponding test breaks the traceability model the spec is built around.
- Measured numbers (latency cycles, resource utilization, timing slack) go in the §12 tables only — never asserted in prose elsewhere in the spec or README.
- §0's reconciliation table records every deliberate behavior change vs. superseded source specs — update it whenever a change alters previously-documented behavior.
- The register map (§9), counter set (§10), and directed test list (§11.4) are cross-referenced from RTL module names (§13's `rtl/` tree) — keep names consistent across all three when adding to any of them.

## Hard conventions for future code

- Hand-written RTL is **Verilog-2001 only** (synthesizable subset, no SystemVerilog) under `rtl/` (NFR-9); the sole exception is hls4ml/Vitis-HLS-generated IP, wrapped by hand-written Verilog (`ml_classifier_wrap.v`) and never edited directly.
- Target device: Artix-7 `XC7A35T-2FGG484I` (ALINX AX7035B board, Micrel KSZ9031RNX PHY, RGMII), single 125 MHz clock domain (8 ns period), Vivado 2023.x+ / Vitis HLS 2023.x+ (2024.2 verified locally, see `PREREQUISITES.md`).
- Prices and quantities are integer ticks, never floats, anywhere — RTL, golden model, or labeler. Exact comparison, no float arithmetic, no DSP for price math. Integer mid is `(bid+ask)>>1` everywhere.
- ML is a **risk gate** (`0x09`), not the trading signal: `z = b + Σ w_i·x_i`, `int8` weights/features, `int32` accumulator. It can only block/reduce an order; it never overrides the kill switch, position limits, size limits, price band, staleness, or sequence-gap checks — deterministic gates `0x01`–`0x08` always dominate the reported reject reason.
- The two datapath halves (deterministic signal path, ~2 cycles; ML path — features → classifier → hysteresis, ~7–10 cycles) run in parallel after a book update and are re-aligned via a fixed-depth register before the risk engine, so tick-to-trade stays a fixed cycle count even with ML in the path (single-occupancy latency histogram: max == min). Don't break that invariant when touching `signal_engine`/`ml_*`/the alignment stage.
- hls4ml flow: Python (Keras) → hls4ml (Vitis backend, part `xc7a35tfgg484-2`, `io_parallel`) → Vitis HLS IP. The hls4ml C-simulation (csim) must be bit-exact against the Python fixed-point golden model on every exported golden vector before the IP is handed off — a hard gate per `ml_engineer_brief.md` §8.3, not a nice-to-have.
- Golden models are written **from the spec**, not from the RTL — a model derived from the RTL only confirms the RTL matches itself.

## Planned repository layout (master spec §13)

Authored/versioned vs. generated/ignored is the organizing rule — **if the build can regenerate it, it does not go in version control** (checkpoints, bitstreams, reports, logs, waveforms, the Vivado project file, the block-design binary blob are all ignored; `.xci` IP config is the one generated-but-versioned exception). A `.gitignore` already covers Office lock files, hls4ml build output (`hls4ml/*_prj/`, `vitis_hls.log`, `.Xil/`), and Vivado artifacts (`*.jou`, `*.log`, `.Xil/`) — extend it as new generated paths appear (bitstreams, waveform databases, checkpoints) rather than committing them.

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

## Big-picture architecture (for orientation — see master spec §3 for full detail)

Ingress → parse → filter → book state, then **two convergent paths** running in parallel, realigned before risk:

```
md_parser → symbol_filter → seq_monitor → tob_engine
                                             ├─ feature_extractor → feature_normalizer(int8) → ml_classifier_wrap (hls4ml IP) → ml_policy(hysteresis) ─┐
                                             └─ signal_engine (spread + imbalance rule) ─────────────────────────────────────────[align]──┴→ risk_engine (9 gates, incl. 0x09 ML) → order_builder → eth_mac_tx
```

- **Decision rule:** after a book update, buy when `spread ≥ cfg_min_spread` and `bid_qty > (ask_qty << cfg_imb_shift)`; sell under the mirror condition; both require a valid, non-crossed book.
- **Wire format:** fixed-width 16-byte big-endian market-data messages (`msg_type`, `symbol_id`, `side`, `flags`, `price` u32, `quantity` u32, `seq_num`), 1–88 packed per Ethernet frame. Order-output frames carry `trigger_seq` and the measured `latency_cyc`, so the host's order capture doubles as a latency log.
- **ML model (v1):** linear classifier `z = b + Σ w_i·x_i` (monotonic, no sigmoid needed at inference), 8 fixed-point features computed in RTL (spread, mid-price delta, book imbalance, bid/ask size changes, update rate, last trade direction, short-term volatility). The adverse-selection label is a synthetic proxy (mid moves ≥1 tick against the quoted side within `H` future events) — it demonstrates the FPGA inference path, not real market microstructure. Never claim this predicts real adverse selection.
- **Honest limitations to preserve in any future docs/code comments:** simulated trading only; proxy ML label; optimistic immediate-fill model; snapshot-replace book (not incremental multi-level — that's v2).

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
