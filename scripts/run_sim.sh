#!/usr/bin/env bash
# scripts/run_sim.sh -- runs every self-checking test in the repo, non-zero
# exit on any failure (master spec S13's stated purpose for this script;
# CI's golden-model-sim job in .github/workflows/ci.yml calls this).
#
# Covers: both Python golden-model hand-cases, order_rx.py's decode
# self-test, an RTL-lint compile of all hand-written rtl/ (Verilog-2001),
# every per-module testbench in tb/, and (unless RUN_SIM_FAST=1) the S2
# 1,000,000-message parser soak, which is slow under Icarus (a few minutes)
# and regenerates its stimulus file on demand since tb/stimulus/*.mem is
# gitignored (regenerable, ~16 MB at 1M messages -- see
# sim/gen_soak_vectors.py's own header for why).
#
# Does NOT run anything needing Vivado/XSim (Xilinx primitives, real IP
# sim models) -- that's scripts/build.tcl's job, not this one. Verilog-2001
# only, per NFR-9 / CLAUDE.md.
#
# Usage:
#   bash scripts/run_sim.sh              # full regression
#   RUN_SIM_FAST=1 bash scripts/run_sim.sh   # skip the 1M-message soak

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root, regardless of invocation cwd

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAIL=0
FAILED_TESTS=()

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1"
    FAIL=1
    FAILED_TESTS+=("$1")
}

run_tb() {
    local name="$1"; shift
    local out="$WORKDIR/${name}.vvp"
    local compile_log="$WORKDIR/${name}.compile.log"
    local run_log="$WORKDIR/${name}.run.log"
    if ! iverilog -g2001 -o "$out" "tb/${name}.v" "$@" >"$compile_log" 2>&1; then
        fail "$name (compile error)"
        cat "$compile_log"
        return
    fi
    if ! vvp "$out" >"$run_log" 2>&1; then
        fail "$name (simulator crashed)"
        cat "$run_log"
        return
    fi
    if grep -qi "FAIL" "$run_log"; then
        fail "$name"
        cat "$run_log"
    elif grep -qi "PASS" "$run_log"; then
        pass "$name"
    else
        fail "$name (no PASS/FAIL marker in output)"
        cat "$run_log"
    fi
}

echo "=== Python golden-model regressions ==="
python sim/test_golden_model_handcase.py && pass "sim/test_golden_model_handcase.py" || fail "sim/test_golden_model_handcase.py"
python sim/test_feature_golden_handcase.py && pass "sim/test_feature_golden_handcase.py" || fail "sim/test_feature_golden_handcase.py"
python sim/order_rx.py --selftest && pass "sim/order_rx.py --selftest" || fail "sim/order_rx.py --selftest"

echo
echo "=== RTL lint (Verilog-2001, hand-written rtl/ only -- not vendor/) ==="
if iverilog -g2001 -Wall -o "$WORKDIR/lint.vvp" rtl/*.v rtl/common/*.v; then
    pass "rtl-lint"
else
    fail "rtl-lint"
fi

echo
echo "=== Per-module testbenches ==="
run_tb tb_counter_sat rtl/common/counter_sat.v
run_tb tb_sync_2ff rtl/common/sync_2ff.v
run_tb tb_mdio_ctrl rtl/common/mdio_ctrl.v
run_tb tb_eth_mac_if_rx rtl/eth_mac_if.v
run_tb tb_eth_mac_if_tx rtl/eth_mac_if.v tb/sim_models/xilinx_ip_sim_models.v \
    rtl/vendor/alinx_mac/mac_top.v rtl/vendor/alinx_mac/crc.v rtl/vendor/alinx_mac/dpram.v \
    rtl/vendor/alinx_mac/arp_cache.v rtl/vendor/alinx_mac/icmp_reply.v \
    rtl/vendor/alinx_mac/rx/*.v rtl/vendor/alinx_mac/tx/*.v
run_tb tb_frame_classifier rtl/frame_classifier.v
run_tb tb_md_parser rtl/md_parser.v
run_tb tb_symbol_filter rtl/symbol_filter.v
run_tb tb_seq_monitor rtl/seq_monitor.v
run_tb tb_tob_engine rtl/tob_engine.v
run_tb tb_feature_extractor rtl/feature_extractor.v
run_tb tb_feature_normalizer rtl/feature_normalizer.v
run_tb tb_signal_engine rtl/signal_engine.v
run_tb tb_signal_tob_chain rtl/tob_engine.v rtl/signal_engine.v
run_tb tb_risk_engine rtl/risk_engine.v
run_tb tb_order_builder rtl/order_builder.v
run_tb tb_csr_block rtl/csr_block.v
run_tb tb_latency_histogram rtl/latency_histogram.v

if [ "${RUN_SIM_FAST:-0}" != "1" ]; then
    echo
    echo "=== S2 gate: 1,000,000-message parser soak (slow; RUN_SIM_FAST=1 to skip) ==="
    if [ ! -f tb/stimulus/s2_soak.mem ]; then
        python sim/gen_soak_vectors.py --seed 7 --out tb/stimulus/s2_soak.mem
    fi
    run_tb tb_parser_soak rtl/frame_classifier.v rtl/md_parser.v
else
    echo
    echo "RUN_SIM_FAST=1: skipping the 1,000,000-message soak"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "FAILED (${#FAILED_TESTS[@]}): ${FAILED_TESTS[*]}"
    exit 1
fi
