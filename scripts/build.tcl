# Non-project-mode Vivado build. fpga_project_flow.md Stage 2: one reviewable
# script, no .xpr, reproducible on any machine with Vivado + this repo.
#
# Usage: vivado -mode batch -source scripts/build.tcl
#
# Gates enforced (a bitstream is never written if these fail):
#   - zero inferred latches
#   - non-negative worst negative slack (WNS)

set part    "xc7a35tfgg484-2"
set top     "tob_top"
set rtl_dir "rtl"
set xdc_files [list constraints/tob_pins.xdc constraints/tob_timing.xdc]
set out_dir "results/build"

file mkdir $out_dir

create_project -in_memory -part $part

# Only the S0 skeleton exists today; this glob picks up new modules as they land.
add_files -norecurse [glob -nocomplain $rtl_dir/*.v $rtl_dir/common/*.v]
foreach f $xdc_files { read_xdc $f }

set_property top $top [current_fileset]

synth_design -top $top -part $part

set latch_count [llength [get_cells -hierarchical -filter {IS_LATCH == 1}]]
if {$latch_count > 0} {
    puts "ERROR: $latch_count inferred latch(es) found -- failing build."
    exit 1
}

report_utilization -file $out_dir/utilization_synth.rpt

opt_design
place_design
route_design

set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
puts "WNS = $wns ns"
if {$wns < 0} {
    puts "ERROR: negative slack (WNS = $wns ns) -- refusing to write a bitstream."
    exit 1
}

report_utilization -file $out_dir/utilization.rpt
report_timing_summary -file $out_dir/timing_summary.rpt

write_bitstream -force $out_dir/$top.bit

puts "Build OK: $out_dir/$top.bit (WNS = $wns ns)"
