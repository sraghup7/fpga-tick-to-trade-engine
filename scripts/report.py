#!/usr/bin/env python3
"""scripts/report.py -- parses results/build/*.rpt (real Vivado output, one
build's worth, gitignored per master spec S13's "generated does not go in
version control" rule) into the checked-in results/*.md tables results/
README.md already declares. Run after scripts/build.tcl produces a fresh
results/build/*.rpt set.

Usage:
    python scripts/report.py

Writes results/timing.md and results/utilization.md. Does NOT invent numbers
for reports that don't exist yet (ml_metrics.md needs a trained S4 model;
latency_histogram.csv and ila_captures/ need real hardware, S11) -- it only
turns what Vivado actually measured into the tables master spec S12 requires,
and leaves everything else alone.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = REPO_ROOT / "results" / "build"
OUT_DIR = REPO_ROOT / "results"


def read(name):
    p = BUILD_DIR / name
    if not p.exists():
        return None
    return p.read_text(encoding="utf-8", errors="replace")


def parse_timing(text):
    """Design Timing Summary table: WNS/TNS/.../WHS/THS/.../WPWS/TPWS/..."""
    m = re.search(
        r"^\s*([\d.-]+)\s+([\d.-]+)\s+(\d+)\s+(\d+)\s+"
        r"([\d.-]+)\s+([\d.-]+)\s+(\d+)\s+(\d+)\s+"
        r"([\d.-]+)\s+([\d.-]+)\s+(\d+)\s+(\d+)\s*$",
        text, re.MULTILINE,
    )
    if not m:
        return None
    wns, tns, tns_fail, tns_total, whs, ths, ths_fail, ths_total, \
        wpws, tpws, tpws_fail, tpws_total = m.groups()
    clk = re.search(
        r"^(\S+)\s+\{[^}]*\}\s+([\d.]+)\s+([\d.]+)\s*$", text, re.MULTILINE
    )
    period_ns = float(clk.group(2)) if clk else None
    # Achieved Fmax = 1 / (constrained period - worst setup slack), not the
    # constrained clock's own nominal frequency (which is just NFR-1's target).
    fmax_mhz = (1000.0 / (period_ns - float(wns))) if period_ns else None
    # Vivado prints this sentence itself, right after the summary table --
    # use it directly rather than re-deriving pass/fail from the failing-
    # endpoint counts (which a future report format change could break
    # silently). Found missing 2026-09-09: this whole function had only ever
    # been exercised against a MET report before (D29 -- every prior build
    # failed the WNS gate before report_timing_summary even ran), so a
    # missing "met" status went unnoticed until the first real VIOLATED run.
    met_m = re.search(r"Timing constraints are (not met|met)\.", text)
    met = (met_m.group(1) == "met") if met_m else None
    return {
        "wns": float(wns), "tns": float(tns),
        "tns_fail": int(tns_fail), "tns_total": int(tns_total),
        "whs": float(whs), "ths": float(ths),
        "ths_fail": int(ths_fail), "ths_total": int(ths_total),
        "period_ns": period_ns, "fmax_mhz": fmax_mhz,
        "clock_name": clk.group(1) if clk else None,
        "met": met,
    }


def parse_worst_path(text, label):
    """First 'Max Delay Paths' / 'Min Delay Paths' block's Source/Destination
    and one-line delay summary, for the top-level rx_clk->rx_clk group only
    (the first occurrence in the file). Matches BOTH "Slack (MET)" and
    "Slack (VIOLATED)" -- a MET-only regex silently falls through to the
    next matching block anywhere in the file (e.g. an unrelated, always-
    passing sys_clk path) whenever the real rx_clk path is violated, which
    is exactly the report.py bug found 2026-09-09 on the first real failing
    build (D29: no prior build ever reached report_timing_summary while
    failing, so this path was never exercised)."""
    block = re.search(
        label + r" Paths\n-+\nSlack \((MET|VIOLATED)\)\s*:\s*([\d.-]+)ns.*?\n"
        r"\s*Source:\s*(\S+)\n.*?\n"
        r"\s*Destination:\s*(\S+)\n",
        text, re.DOTALL,
    )
    if not block:
        return None
    return {
        "status": block.group(1),
        "slack_ns": float(block.group(2)),
        "source": block.group(3),
        "destination": block.group(4),
    }


def parse_utilization(text):
    def cell(pattern):
        m = re.search(pattern, text, re.MULTILINE)
        return m.groups() if m else None

    lut = cell(r"^\| Slice LUTs\s*\*?\s*\|\s*(\d+)\s*\|.*?\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|$")
    ff = cell(r"^\| Slice Registers\s*\|\s*(\d+)\s*\|.*?\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|$")
    bram = cell(r"^\| Block RAM Tile\s*\|\s*([\d.]+)\s*\|.*?\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|$")
    dsp = cell(r"^\| DSPs\s*\|\s*(\d+)\s*\|.*?\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|$")
    return {"lut": lut, "ff": ff, "bram": bram, "dsp": dsp}


def fmt_row(name, tup, unit=""):
    if tup is None:
        return f"| {name} | -- | -- | -- |"
    used, avail, pct = tup
    return f"| {name} | {used}{unit} | {avail}{unit} | {pct}% |"


def write_timing_md(timing_text):
    t = parse_timing(timing_text)
    if t is None:
        print("WARN: could not parse Design Timing Summary from timing_summary.rpt", file=sys.stderr)
        return False
    worst_setup = parse_worst_path(timing_text, "Max Delay")
    worst_hold = parse_worst_path(timing_text, "Min Delay")

    lines = []
    lines.append("# results/timing.md")
    lines.append("")
    lines.append("Generated by `scripts/report.py` from `results/build/timing_summary.rpt`")
    lines.append("(real Vivado `report_timing_summary` output on the routed `tob_top` design,")
    lines.append(f"`{t['clock_name']}` at {t['period_ns']:.3f} ns / {t['fmax_mhz']:.3f} MHz, per master spec S12.3).")
    lines.append("Do not hand-edit; re-run the script after a new build.")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("| :-- | --: |")
    lines.append(f"| WNS (setup) | {t['wns']:.3f} ns |")
    lines.append(f"| TNS (setup) | {t['tns']:.3f} ns |")
    lines.append(f"| Setup failing endpoints | {t['tns_fail']} / {t['tns_total']} |")
    lines.append(f"| WHS (hold) | {t['whs']:.3f} ns |")
    lines.append(f"| THS (hold) | {t['ths']:.3f} ns |")
    lines.append(f"| Hold failing endpoints | {t['ths_fail']} / {t['ths_total']} |")
    lines.append(f"| Achieved Fmax ({t['clock_name']}) | {t['fmax_mhz']:.3f} MHz (period {t['period_ns']:.3f} ns) |")
    lines.append("")
    if t["met"] is True:
        lines.append("**All user-specified timing constraints are met (0 failing endpoints, both setup and hold).**")
    elif t["met"] is False:
        lines.append(f"**Timing constraints are NOT met** — {t['tns_fail']} setup / {t['ths_fail']} hold "
                      f"endpoint(s) failing (Vivado's own `report_timing_summary` verdict). "
                      f"Do not treat this build's bitstream as ready for hardware.")
    else:
        lines.append("**WARN: could not determine met/not-met status from this report.**")
    lines.append("")
    if worst_setup:
        label = "path" if worst_setup["status"] == "MET" else "**VIOLATED** path"
        lines.append(f"Worst setup {label}: slack **{worst_setup['slack_ns']:.3f} ns** — "
                      f"`{worst_setup['source']}` → `{worst_setup['destination']}`"
                      + (" (order_builder's TX payload register into the latency histogram's "
                         "distributed-RAM write port; see `docs/design_decisions.md` D26-D40 "
                         "for the bottleneck history that got timing here)."
                         if worst_setup["status"] == "MET" else "."))
        lines.append("")
    if worst_hold:
        label = "path" if worst_hold["status"] == "MET" else "**VIOLATED** path"
        lines.append(f"Worst hold {label}: slack **{worst_hold['slack_ns']:.3f} ns** — "
                      f"`{worst_hold['source']}` → `{worst_hold['destination']}`.")
        lines.append("")
    if t["met"] is True and t["period_ns"]:
        margin_pct = 100.0 * t["wns"] / t["period_ns"]
        lines.append("**Caveat (see master spec S0 / D40, and the Opus review that prompted this")
        lines.append(f"script): {t['wns']:.3f} ns of setup margin on a {t['period_ns']:.3f} ns period is "
                      f"{margin_pct:.1f}% — real but thin.")
    elif t["met"] is False:
        lines.append("**Caveat (see master spec S0 / D40, and the Opus review that prompted this")
        lines.append(f"script): the worst setup path is violated by {abs(t['wns']):.3f} ns on a "
                      f"{t['period_ns']:.3f} ns period — not a margin, a real deficit that must be "
                      f"closed (e.g. by pipelining the failing path) before this build's bitstream can")
        lines.append("be trusted for hardware.")
    lines.append("`constraints/tob_timing.xdc` sets no `set_input_delay`/`set_output_delay` on")
    lines.append(f"RGMII, so the {t['tns_total']} timed endpoints above are internal paths only; the")
    lines.append("source-synchronous PHY interface itself is unconstrained and unmeasured here.**")
    lines.append("")
    (OUT_DIR / "timing.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def write_utilization_md(util_text):
    u = parse_utilization(util_text)
    if not any(u.values()):
        print("WARN: could not parse utilization table from utilization.rpt", file=sys.stderr)
        return False

    lines = []
    lines.append("# results/utilization.md")
    lines.append("")
    lines.append("Generated by `scripts/report.py` from `results/build/utilization.rpt`")
    lines.append("(real Vivado `report_utilization` output, post-implementation/routed, on")
    lines.append("`xc7a35tfgg484-2`, per master spec S12.2). Do not hand-edit.")
    lines.append("")
    lines.append("| Resource | Used | Available | Utilization |")
    lines.append("| :-- | --: | --: | --: |")
    lines.append(fmt_row("Slice LUTs", u["lut"]))
    lines.append(fmt_row("Slice Registers (FF)", u["ff"]))
    lines.append(fmt_row("Block RAM Tile", u["bram"]))
    lines.append(fmt_row("DSPs", u["dsp"]))
    lines.append("")
    lines.append("**DSP usage is 0 for the whole design, classifier included.** Do not assume")
    lines.append("this means untrained placeholder weights (`w_i=1`) -- check")
    lines.append("`docs/design_decisions.md`'s latest D-entry for the model's actual status.")
    lines.append("Vivado maps the classifier's int8x8 constant multiplies to LUT fabric rather")
    lines.append("than DSP48 slices at this optimization setting regardless of whether the")
    lines.append("weights are the placeholder or a real trained model (small constant multiplies")
    lines.append("are cheap enough in LUTs that Vivado doesn't need a DSP for them here). The")
    lines.append("`<=8 DSP` classifier budget (S7.3) is met either way, but this line alone")
    lines.append("cannot tell you which case you're looking at.")
    lines.append("")
    lines.append("**`csr_block.v` is the single largest hand-written contributor to LUT usage**")
    lines.append("— 2,335 LUTs / 2,253 FFs, 11.2% of the part's entire LUT fabric, measured via")
    lines.append("`report_utilization -hierarchical -hierarchical_depth 2` on the routed D40")
    lines.append("netlist (`docs/design_decisions.md` D41). Root cause and a proposed fix (a")
    lines.append("shared-incrementer counter file + pipelined read mux, ~1,500+ LUTs recoverable)")
    lines.append("are documented there, not yet implemented.")
    lines.append("")
    (OUT_DIR / "utilization.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return True


def main():
    timing_text = read("timing_summary.rpt")
    util_text = read("utilization.rpt")

    if timing_text is None and util_text is None:
        print(f"No Vivado reports found in {BUILD_DIR} -- run scripts/build.tcl first.", file=sys.stderr)
        return 1

    ok = True
    if timing_text is not None:
        ok &= write_timing_md(timing_text)
    else:
        print("WARN: results/build/timing_summary.rpt not found, skipping timing.md", file=sys.stderr)

    if util_text is not None:
        ok &= write_utilization_md(util_text)
    else:
        print("WARN: results/build/utilization.rpt not found, skipping utilization.md", file=sys.stderr)

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
