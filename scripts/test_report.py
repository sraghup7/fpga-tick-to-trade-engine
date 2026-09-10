"""scripts/test_report.py

Hand-case regression for scripts/report.py's timing-report parsing, same
spirit as sim/test_*_handcase.py. Exercises both a MET (passing) and a
VIOLATED (failing) `results/build/timing_summary.rpt` shape.

Root cause this guards against (found 2026-09-09, first real failing-timing
build ever run against this script -- see docs/design_decisions.md): every
build before this one failed the WNS gate *before* reaching
`report_timing_summary` (D29), so report.py's timing-report parsing had
never actually been exercised against a report describing a genuinely
failing build. Two bugs were latent as a result:
  1. `parse_worst_path()`'s regex required a literal "Slack (MET)", so on a
     violated rx_clk path it silently skipped past the real (VIOLATED)
     block and matched an unrelated, always-passing sys_clk block instead.
  2. `write_timing_md()`'s "all constraints are met" sentence was a
     hardcoded string, never derived from the parsed pass/fail data --
     even though Vivado's own report prints "Timing constraints are not
     met." right there for the taking.

Run: python scripts/test_report.py
"""
from report import parse_timing, parse_worst_path, write_timing_md, OUT_DIR

failures = []


def check(label, actual, expected):
    if actual != expected:
        failures.append(f"{label}: got {actual!r}, expected {expected!r}")


# ---------------------------------------------------------------------------
# Fixture: a real captured VIOLATED report (results/build/timing_summary.rpt,
# 2026-09-09, real trained ML weights synthesized for the first time --
# excerpted to the sections parse_timing/parse_worst_path actually read).
# ---------------------------------------------------------------------------
VIOLATED_FIXTURE = """
------------------------------------------------------------------------------------------------
| Design Timing Summary
| ---------------------
------------------------------------------------------------------------------------------------

    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
     -3.842     -279.719                    522                31365        0.045        0.000                      0                31365        2.870        0.000                       0                 11602


Timing constraints are not met.


------------------------------------------------------------------------------------------------
| Clock Summary
| -------------
------------------------------------------------------------------------------------------------

Clock    Waveform(ns)         Period(ns)      Frequency(MHz)
-----    ------------         ----------      --------------
rx_clk   {0.000 4.000}        8.000           125.000
sys_clk  {0.000 10.000}       20.000          50.000

From Clock:  rx_clk
  To Clock:  rx_clk

Setup :          342  Failing Endpoints,  Worst Slack       -3.842ns,  Total Violation     -201.165ns
Hold  :            0  Failing Endpoints,  Worst Slack        0.045ns,  Total Violation        0.000ns
---------------------------------------------------------------------------------------------------


Max Delay Paths
--------------------------------------------------------------------------------------
Slack (VIOLATED) :        -3.842ns  (required time - arrival time)
  Source:                 u_norm/x7_reg[5]/C
                            (rising edge-triggered cell FDCE clocked by rx_clk  {rise@0.000ns fall@4.000ns period=8.000ns})
  Destination:            u_ml/z_reg[29]/D
                            (rising edge-triggered cell FDCE clocked by rx_clk  {rise@0.000ns fall@4.000ns period=8.000ns})
  Path Group:             rx_clk

Min Delay Paths
--------------------------------------------------------------------------------------
Slack (MET) :             0.045ns  (arrival time - required time)
  Source:                 u_align/data_pipe_reg[3][38]/C
                            (rising edge-triggered cell FDCE clocked by rx_clk  {rise@0.000ns fall@4.000ns period=8.000ns})
  Destination:            u_risk/r1_price_reg[6]/D
                            (rising edge-triggered cell FDCE clocked by rx_clk  {rise@0.000ns fall@4.000ns period=8.000ns})
  Path Group:             rx_clk

From Clock:  sys_clk
  To Clock:  sys_clk

Setup :            0  Failing Endpoints,  Worst Slack       15.525ns,  Total Violation        0.000ns
Hold  :            0  Failing Endpoints,  Worst Slack        0.178ns,  Total Violation        0.000ns
---------------------------------------------------------------------------------------------------


Max Delay Paths
--------------------------------------------------------------------------------------
Slack (MET) :             15.525ns  (required time - arrival time)
  Source:                 u_mdio/settle_cnt_reg[2]/C
                            (rising edge-triggered cell FDCE clocked by sys_clk  {rise@0.000ns fall@10.000ns period=20.000ns})
  Destination:            u_mdio/settle_cnt_reg[0]/CE
                            (rising edge-triggered cell FDCE clocked by sys_clk  {rise@0.000ns fall@10.000ns period=20.000ns})
  Path Group:             sys_clk

Min Delay Paths
--------------------------------------------------------------------------------------
Slack (MET) :             0.178ns  (arrival time - required time)
  Source:                 u_mdio/foo_reg/C
  Destination:            u_mdio/bar_reg/D
  Path Group:             sys_clk
"""

# A MET (passing) fixture, matching the shape this script has always been
# tested against historically (D40's original passing build) -- must still
# work identically after the fix.
MET_FIXTURE = """
------------------------------------------------------------------------------------------------
| Design Timing Summary
| ---------------------
------------------------------------------------------------------------------------------------

    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
      0.141        0.000                      0                31058        0.043        0.000                      0                31058        3.000        0.000                       0                 11000


Timing constraints are met.


------------------------------------------------------------------------------------------------
| Clock Summary
| -------------
------------------------------------------------------------------------------------------------

Clock    Waveform(ns)         Period(ns)      Frequency(MHz)
-----    ------------         ----------      --------------
rx_clk   {0.000 4.000}        8.000           125.000

From Clock:  rx_clk
  To Clock:  rx_clk

Setup :            0  Failing Endpoints,  Worst Slack        0.141ns,  Total Violation        0.000ns
Hold  :            0  Failing Endpoints,  Worst Slack        0.043ns,  Total Violation        0.000ns
---------------------------------------------------------------------------------------------------


Max Delay Paths
--------------------------------------------------------------------------------------
Slack (MET) :             0.141ns  (required time - arrival time)
  Source:                 u_ob/tx_payload_reg[8]/C
  Destination:            u_hist/hist_mem_reg_r1_0_63_27_29/RAMB/I
  Path Group:             rx_clk

Min Delay Paths
--------------------------------------------------------------------------------------
Slack (MET) :             0.043ns  (arrival time - required time)
  Source:                 u_align/data_pipe_reg[3][38]/C
  Destination:            u_risk/r1_price_reg[6]/D
  Path Group:             rx_clk
"""

# ---------------------------------------------------------------------------
# Test 1: parse_timing on the VIOLATED fixture picks up the correct
# met/not-met status from Vivado's own printed sentence.
# ---------------------------------------------------------------------------
t_violated = parse_timing(VIOLATED_FIXTURE)
check("violated.wns", t_violated["wns"], -3.842)
check("violated.tns_fail", t_violated["tns_fail"], 522)
check("violated.met", t_violated["met"], False)

# ---------------------------------------------------------------------------
# Test 2: parse_worst_path on the VIOLATED fixture must find rx_clk's real
# violated path (u_norm -> u_ml), NOT sys_clk's unrelated passing one
# (u_mdio -> u_mdio) that a MET-only regex would fall through to.
# ---------------------------------------------------------------------------
worst_setup_violated = parse_worst_path(VIOLATED_FIXTURE, "Max Delay")
check("violated.worst_setup.status", worst_setup_violated["status"], "VIOLATED")
check("violated.worst_setup.slack_ns", worst_setup_violated["slack_ns"], -3.842)
check("violated.worst_setup.source", worst_setup_violated["source"], "u_norm/x7_reg[5]/C")
check("violated.worst_setup.destination", worst_setup_violated["destination"], "u_ml/z_reg[29]/D")

worst_hold_violated = parse_worst_path(VIOLATED_FIXTURE, "Min Delay")
check("violated.worst_hold.status", worst_hold_violated["status"], "MET")
check("violated.worst_hold.slack_ns", worst_hold_violated["slack_ns"], 0.045)

# ---------------------------------------------------------------------------
# Test 3: parse_timing/parse_worst_path on the MET fixture reproduce the
# original, already-correct passing-build behavior unchanged.
# ---------------------------------------------------------------------------
t_met = parse_timing(MET_FIXTURE)
check("met.wns", t_met["wns"], 0.141)
check("met.met", t_met["met"], True)

worst_setup_met = parse_worst_path(MET_FIXTURE, "Max Delay")
check("met.worst_setup.status", worst_setup_met["status"], "MET")
check("met.worst_setup.slack_ns", worst_setup_met["slack_ns"], 0.141)
check("met.worst_setup.source", worst_setup_met["source"], "u_ob/tx_payload_reg[8]/C")

# ---------------------------------------------------------------------------
# Test 4: write_timing_md's generated prose must actually say "not met" for
# the violated fixture (not the old hardcoded "all constraints are met"),
# and must quote the real violated path, not the unrelated sys_clk one.
# ---------------------------------------------------------------------------
write_timing_md(VIOLATED_FIXTURE)
generated = (OUT_DIR / "timing.md").read_text(encoding="utf-8")
check("generated.mentions_not_met", "not met" in generated.lower(), True)
check("generated.mentions_real_worst_path", "u_norm/x7_reg[5]/C" in generated, True)
check("generated.does_not_mention_wrong_path", "u_mdio/settle_cnt_reg" in generated, False)
check("generated.does_not_claim_all_met",
      "All user-specified timing constraints are met" in generated, False)

if failures:
    print(f"FAIL ({len(failures)} mismatch(es)):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)

print("PASS: report.py's timing parser handles both MET and VIOLATED builds correctly")
