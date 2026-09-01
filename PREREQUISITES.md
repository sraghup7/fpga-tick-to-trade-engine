# Prerequisites

Everything needed to build, simulate, synthesize, and bring up the
tick-to-trade engine. Status was verified against the machine on 2026-08-31,
re-verified 2026-09-01 (see §7 for that pass's findings).

Reference: `fpga_tick_to_trade_master_spec.md` (single source of truth),
`fpga_project_flow.md` (process). Target: Artix-7 `XC7A35T-2FGG484I`
(ALINX AX7035B), Vivado/Vitis HLS 2024.2, Verilog-2001 RTL.

---

## 1. Toolchain — verified installed

| Tool | Version | Path | Used for |
| :-- | :-- | :-- | :-- |
| Vivado | 2024.2 | `D:\Vivado\2024.2` | synthesis, implementation, bitstream, XSim, XDC, ILA |
| Vitis (incl. Vitis HLS) | 2024.2 | `D:\Vitis\2024.2` | hls4ml IP export (ML collaborator, §5.6) |
| Python | 3.11.15 | `python` (PATH) | golden models, stimulus, compare scripts |
| Icarus Verilog | 12.0 (devel) | `C:\iverilog\bin` | fast lint + Verilog-2001 sim (NOT on PATH — fix below) |
| GTKWave | — | `C:\iverilog\gtkwave\bin` | waveform viewer (NOT on PATH — fix below) |
| Git + Git Bash | 2.55 | PATH / `C:\Program Files\Git\bin\bash.exe` | VCS, `make`/`run_sim.sh` runner |

Notes:
- Spec targets Vivado "2023.x or later"; 2024.2 qualifies. Confirm the exact
  part string `xc7a35tfgg484-2` is accepted (§17.8) and pin hls4ml ↔ Vitis HLS
  2024.2 compatibility (§17.9).
- Icarus 12.0 is a 2015-era devel snapshot: fine for Verilog-2001, but keep
  testbenches plain Verilog (no SVA/SystemVerilog features Icarus can't parse).
  SVA and any SystemVerilog go to XSim.
- License: WebPACK covers the XC7A35T free of charge — confirm the D:\Vitis
  install license activates on first run.

---

## 2. Toolchain — to install / configure

### 2.1 GNU Make (missing — no `make`/`nmake`/`mingw32-make` on PATH)

The spec's `Makefile` (and §13 `make sim / synth / bit / ml / all`) needs GNU make.

```powershell
winget install GnuWin32.Make        # or: winget install Ezwinports.Make
```

Alternative: run `make` from Git Bash (MSYS2 `make`); or add an MSYS2 make to PATH.
Until make is installed, `run_sim.sh` can be driven directly from Git Bash.

### 2.2 Add Icarus + GTKWave to PATH (user-level)

```powershell
[Environment]::SetEnvironmentVariable("Path",
  [Environment]::GetEnvironmentVariable("Path","User") + ";C:\iverilog\bin;C:\iverilog\gtkwave\bin",
  "User")
```

### 2.3 Python packages (FPGA/verification side)

```powershell
python -m pip install pytest
```

`numpy` (already present) is sufficient for `golden_model.py` / `ml_golden.py` /
`feed_gen.py` / `compare.py`. ML-side packages (`tensorflow`, `hls4ml`, `qkeras`,
`scikit-learn`, `h5py`) are owned by the ML collaborator and pinned in
`hls4ml_flow.md` — not installed here.

---

## 3. Vivado MCP server (AI → Vivado bridge)

Chosen: **`vivado-mcp`** (`mapleleavessssssss-wq/vivado-mcp`).

Why: Windows-native (drives `vivado -mode tcl` via `subprocess`, no pexpect),
30 curated tools (synthesis/impl/bitstream, timing WNS/TNS, utilization, XSim,
`xdc_lint`, `parse_bit_header`, `check_bitstream_readiness`,
`verify_io_placement_tool`), a `doctor` self-check, and it auto-discovers Icarus
for `verilog_compile_check`.

Requires: Python ≥ 3.10 (have 3.11), Vivado installed locally (have 2024.2).

```powershell
python -m pip install vivado-mcp
vivado-mcp doctor                                   # read-only env self-check
```

Configure (opencode, `~/.config/opencode/opencode.jsonc` → `mcp`):

```jsonc
"mcp": {
  "vivado": {
    "type": "stdio",
    "command": "python",
    "args": ["-m", "vivado_mcp"],
    "environment": { "VIVADO_PATH": "D:/Vivado/2024.2/bin/vivado.bat" }
  }
}
```

Optional (only needed for GUI/attach sessions, not the headless `tcl` build path):

```powershell
vivado-mcp install "D:\Vivado\2024.2" --port 9999   # injects Vivado_init.tcl, backs up original
```

Note: the primary build path is **non-project mode** per `fpga_project_flow.md`
Stage 2 — one reviewable `build.tcl` run via `vivado -mode batch -source build.tcl`.
The MCP server is for interactive timing/ILA/hierarchy/diagnostic work, not the
reproducible build itself.

---

## 4. Hardware (board on hand)

| Item | Status | Notes |
| :-- | :-- | :-- |
| ALINX AX7035B board | ✅ on hand | XC7A35T-2FGG484I, onboard Micrel KSZ9031RNX PHY |
| USB-JTAG | ✅ | "Xilinx ECM driver" present in registry (cable has been used) |
| 1 GbE link + Ethernet cable | ☐ confirm | raw sockets for LINK_MODE=0; static ARP for Mode 1 (§4.1) |
| Board power supply | ☐ confirm | |
| Oscilloscope (optional) | ☐ | §11.6.4 wire-to-wire measurement |

For LINK_MODE=1 (UDP) the host needs a static ARP entry (§4.1):

```bash
sudo arp -s 192.168.1.10 00:0a:35:01:02:03
```

---

## 5. Manuals, datasheets, reference projects (to acquire)

Keep these in `docs/refs/` (gitignored binaries/PDFs; link sources in README).

| Document | Needed for |
| :-- | :-- |
| Artix-7 datasheet (DS181) | resource counts: 20,800 LUT / 41,600 FF / 50 BRAM36 / 90 DSP (NFR-7) |
| 7-Series CLB (UG474), BRAM (UG473), DSP48E1 (UG479) | inference patterns (recognizable code → dedicated blocks) |
| 7-Series Packaging & Pinout (UG475) | pin map |
| **ALINX AX7035B user manual + schematic** | RGMII/LED/key/JTAG pinout → `tob_pins.xdc` (critical) |
| **Micrel KSZ9031RNX datasheet** | RGMII timing + register config (spec §16 risk) |
| Vivado UG901 (synthesis), UG903 (constraints), UG906 (timing), UG908 (debug/ILA) | stages 6–7 + §12.3 critical-path analysis |
| Vitis HLS UG1399 | ML collaborator (§5.6) |
| hls4ml documentation | ML collaborator |
| **ALINX Ethernet example project** | RGMII bring-up reference (spec §16 mitigation: "bring up the ALINX Ethernet example first") |

---

## 6. Open items to resolve during S0 (spec §17)

1. MAC interface shape: 8-bit valid/last stream vs AXI4-Stream (`tkeep`/`tready`).
2. MAC RX error signalling: after-the-fact flag vs frame suppression.
3. `LINK_MODE` at bring-up: Raw-Ethernet (default) vs UDP from S2.
4. Board keys on AX7035B: which physical buttons map to kill switch / counter clear / mode select.
5. Reject reporting: `0x11` diagnostic frames vs counters-only.
6. ML normalization: runtime registers (default) vs baked constants.
7. Gate `0x09` semantics: block-only first (default) vs `cfg_ml_action=reduce`.
8. ~~Exact Vivado part string: `xc7a35tfgg484-2` accepted by 2024.2?~~ **Resolved 2026-09-01: yes** — `get_parts -filter {NAME=~xc7a35tfgg484-2}` returns it (siblings `-1`, `-2L`, `-3` also present).
9. hls4ml ↔ Vitis HLS 2024.2 version pin (lock in `hls4ml_flow.md`).

---

## 7. Verification pass — 2026-09-01

Re-checked every item above against the machine; delta from 2026-08-31 only.

**Toolchain (§1):** all still verified — Vivado/Vitis at `D:\Vivado\2024.2` / `D:\Vitis\2024.2`, Python 3.11.15, Icarus 12.0 + GTKWave present under `C:\iverilog\`, Git 2.55.

**§2.1 GNU Make:** still **not installed**, and Git for Windows on this machine does **not** bundle `make` either (checked `Git\usr\bin` and `Git\mingw64\bin` — neither has it). Not blocking yet — no `Makefile` exists in the repo (still spec-only). Install with `winget install GnuWin32.Make` when `make sim`/`make synth` etc. actually land.

**§2.2 Icarus/GTKWave PATH:** still **not** on PATH — the `SetEnvironmentVariable` command in §2.2 has not been run yet.

**§2.3 Python packages:** `pytest` was missing — **installed** (9.1.1) via `python -m pip install pytest`. `numpy` confirmed present (2.4.6).

**§3 Vivado MCP:** confirmed working — `vivado-mcp` 0.3.25 installed, `start_session(mode="tcl")` connects to Vivado 2024.2 cleanly.

**New finding — Windows registry gotcha (not in the original doc):** `vivado-mcp`'s own startup banner warns that `HKCU\Environment\NoDefaultCurrentDirectoryInExePath` is unset on this machine (Windows 11 24H2 defaults this policy **on**), which breaks `launch_simulation`/XSim — `compile.bat` gets spawned without a resolvable path and fails with "not recognized as an internal or external command." Confirmed the registry value is indeed absent. **Not fixed automatically — this is a registry/system-settings change, run it yourself when you're ready to use XSim:**

```powershell
reg add "HKCU\Environment" /v NoDefaultCurrentDirectoryInExePath /d 0 /f
```

Takes effect next login. A temporary per-shell workaround also exists (`set NoDefaultCurrentDirectoryInExePath=0`) if you need XSim before then. Icarus-only simulation is unaffected.

**§4 Hardware:** unchanged — not re-verifiable from software; still needs your own physical confirmation (board power, JTAG cable, Ethernet cable/link, oscilloscope).

**§5 Manuals/datasheets:** all present under `docs/refs/` and `docs/refs/AX7035/DATASHEET/`, including `KSZ9031RNX.pdf` + eval-board docs and the ALINX Ethernet example (`docs/refs/AX7035/SRC/21_ethernet_test/`, plus 4 more Ethernet-integrated examples). **Still missing:** Vitis HLS UG1399 (no local PDF — use AMD's docs site when the ML collaborator needs it).

**MATLAB and Vitis MCP servers** (added 2026-09-01, not part of the original toolchain list): both now registered globally in `~/.claude.json` alongside `vivado` and `hound`. `vitis_mcp` required a fix — see `CLAUDE.md` / `AGENTS.md` "MCP servers" section for the full story (its dependency on the `mcp` SDK collided with `vivado-mcp`'s newer `mcp==2.0.0`; it now runs from its own pinned venv at `E:\Projects\vitis_mcp\.venv`, `mcp==1.29.1`). Both passed a full `initialize` → `tools/list` handshake test. **A Claude Code restart is required for either to appear as callable tools in a running session** — MCP config is read at startup only.

---

## 7. Out of scope for this machine / role

- **ML training & quantization** (`train.py`, hls4ml export, golden vectors) —
  owned by the ML collaborator (§5/§6.5). FPGA side stays behind `ml_classifier_wrap.v`;
  the spec §15 `linear_classifier.v` fallback unblocks the FPGA schedule if the IP is late.
- **hls4ml IP build** runs on the ML collaborator's Vitis HLS install; here we verify
  the wrapper against the hand-written `linear_classifier.v` in simulation.
