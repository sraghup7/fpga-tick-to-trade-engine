# Non-project-mode Vivado build. fpga_project_flow.md Stage 2: one reviewable
# script, no .xpr, reproducible on any machine with Vivado + this repo.
#
# Usage: vivado -mode batch -source scripts/build.tcl
#
# Gates enforced (a bitstream is never written if these fail):
#   - zero inferred latches
#   - non-negative worst negative setup slack (WNS)
#   - non-negative worst hold slack (WHS)
#
# All reports (utilization, timing) are written BEFORE any gate check, not
# after -- a failing build must still leave fresh diagnostics in
# results/build/, not the previous passing run's stale ones (found via
# external audit + independently confirmed, docs/design_decisions.md D29:
# every run since 2026-09-01 had failed the WNS gate and exited before ever
# reaching report_utilization/report_timing_summary, so those two files sat
# frozen at the very first S0-skeleton build while genuinely describing
# nothing about the current design).

set part    "xc7a35tfgg484-2"
set top     "tob_top"
set rtl_dir "rtl"
set xdc_files [list constraints/tob_pins.xdc constraints/tob_timing.xdc]
set out_dir "results/build"
set ip_names [list udp_tx_data_fifo udp_checksum_fifo udp_rx_ram_8_2048 icmp_rx_ram_8_256]

file mkdir $out_dir

create_project -in_memory -part $part

# rtl/vendor/alinx_mac/'s TX/RX datapath depends on four Xilinx fifo_generator/
# blk_mem_gen IP cores (D8, docs/design_decisions.md) -- .xci configs
# committed at rtl/vendor/alinx_mac/ip/<name>/<name>.xci (copied from ALINX's
# own working reference design for this exact board, docs/refs/AX7035/SRC/
# 21_ethernet_test/...). Vivado 2016-2018-era XCI schema; upgrade_ip brings
# them to whatever fifo_generator/blk_mem_gen version this Vivado install
# ships. generate_target produces the synthesizable netlist non-project mode
# needs before synth_design runs.
foreach ip_name $ip_names {
    read_ip $rtl_dir/vendor/alinx_mac/ip/$ip_name/$ip_name.xci
}
upgrade_ip [get_ips]

# These IPs default to out-of-context (per-IP) synthesis, which needs a
# separate synth_design + write_checkpoint + read_checkpoint -cell merge
# step per IP. Simpler and equally valid for a design this size: disable
# OOC so synth_design synthesizes each IP inline as part of the top-level
# run (true "Global Synthesis", Vivado's other supported IP flow) -- no
# manual add_files needed for the IP's own synthesis sources once this is
# set; synth_design resolves them automatically (adding them explicitly
# anyway produces a "file already exists as part of sub-design" critical
# warning, since generate_target already registered them under the .xci).
foreach ip_name [get_ips] {
    set_property GENERATE_SYNTH_CHECKPOINT false \
        [get_files [get_property IP_FILE [get_ips $ip_name]]]
}

generate_target all [get_ips]

# Picks up every hand-written module as it lands, plus the vendor MAC/RGMII
# adapter tob_top.v instantiates (mac_top.v and friends, util_gmii_to_rgmii.v)
# -- NOT tb/sim_models/*.v, which are Icarus-only behavioral stand-ins for
# these same vendor modules and must never reach real synthesis.
add_files -norecurse [glob -nocomplain \
    $rtl_dir/*.v $rtl_dir/common/*.v \
    $rtl_dir/vendor/alinx_mac/*.v \
    $rtl_dir/vendor/alinx_mac/rx/*.v \
    $rtl_dir/vendor/alinx_mac/tx/*.v]
foreach f $xdc_files { read_xdc $f }

set_property top $top [current_fileset]

synth_design -top $top -part $part

# {IS_LATCH == 1} silently fails open: that property isn't set on LDCE cells
# the way it is on some other primitive classes, so this filter can return
# an empty list even when real latches exist -- it did exactly that in the
# 2026-09-04 run of this design (D26 recorded "zero inferred latches --
# verified" from this exact query; a corrected filter run afterward found
# 32 real LDCE latches inside hand-written RTL that this query had missed
# entirely, D29). PRIMITIVE_SUBGROUP is the property that actually
# classifies latch primitives correctly across cell types.
report_utilization -file $out_dir/utilization_synth.rpt

set latch_cells [get_cells -hierarchical -filter {PRIMITIVE_SUBGROUP == LATCH}]
set latch_count [llength $latch_cells]
if {$latch_count > 0} {
    puts "ERROR: $latch_count inferred latch(es) found -- failing build."
    foreach c $latch_cells { puts "  latch: $c" }
    exit 1
}

opt_design
place_design
route_design

# Reports are written BEFORE the gate checks below (see file header) so a
# failing build still leaves fresh, current diagnostics in results/build/.
report_utilization  -file $out_dir/utilization.rpt
report_timing_summary -file $out_dir/timing_summary.rpt

set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -hold] 0]]
puts "WNS = $wns ns"
puts "WHS = $whs ns"
if {$wns < 0} {
    puts "ERROR: negative setup slack (WNS = $wns ns) -- refusing to write a bitstream."
    exit 1
}
if {$whs < 0} {
    puts "ERROR: negative hold slack (WHS = $whs ns) -- refusing to write a bitstream."
    exit 1
}

write_bitstream -force $out_dir/$top.bit

puts "Build OK: $out_dir/$top.bit (WNS = $wns ns, WHS = $whs ns)"
