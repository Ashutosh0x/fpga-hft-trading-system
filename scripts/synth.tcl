# ============================================================================
# Vivado Synthesis Script for FPGA HFT Trading System
# Target: AMD Alveo UL3524 (XCVU2P-FSVJ2104-3-E)
# Clock:  644 MHz (1.553 ns period)
#
# Usage:
#   vivado -mode batch -source scripts/synth.tcl
#
# Outputs:
#   reports/synthesis/utilization_report.txt
#   reports/synthesis/timing_summary.txt
#   reports/synthesis/timing_worst_paths.txt
# ============================================================================

# ---- Project Configuration ----
set project_name    "fpga_hft_system"
set part_name       "xcvu2p-fsvj2104-3-e"
set top_module      "smartnic_top"
set clock_period    1.553
set clock_name      "clk"

# ---- Create Project ----
create_project $project_name ./vivado_project -part $part_name -force

# ---- Add Source Files ----
set rtl_dir "../rtl"
add_files [glob $rtl_dir/*.sv]

# ---- Set Top Module ----
set_property top $top_module [current_fileset]

# ---- Create Clock Constraint ----
set constraint_file [file join ./vivado_project "timing.xdc"]
set xdc_fh [open $constraint_file w]
puts $xdc_fh "# Clock constraint: 644 MHz"
puts $xdc_fh "create_clock -period $clock_period -name $clock_name \[get_ports clk\]"
puts $xdc_fh ""
puts $xdc_fh "# Input/Output delays (estimated)"
puts $xdc_fh "set_input_delay -clock $clock_name -max 0.5 \[get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}\]"
puts $xdc_fh "set_output_delay -clock $clock_name -max 0.5 \[get_ports -filter {DIRECTION == OUT}\]"
puts $xdc_fh ""
puts $xdc_fh "# False paths for async config bus"
puts $xdc_fh "set_false_path -from \[get_ports kill_switch\]"
puts $xdc_fh "set_false_path -from \[get_ports strategy_select*\]"
puts $xdc_fh "set_false_path -from \[get_ports cfg_*\]"
puts $xdc_fh "set_false_path -from \[get_ports wt_*\]"
close $xdc_fh
add_files -fileset constrs_1 $constraint_file

# ---- Run Synthesis ----
puts "================================================================"
puts "Starting synthesis for $top_module on $part_name"
puts "Target clock: $clock_period ns ($clock_name)"
puts "================================================================"

synth_design -top $top_module -part $part_name

# ---- Create Reports Directory ----
file mkdir ../reports/synthesis

# ---- Generate Reports ----
puts "Generating utilization report..."
report_utilization -file ../reports/synthesis/utilization_report.txt

puts "Generating timing summary..."
report_timing_summary -file ../reports/synthesis/timing_summary.txt

puts "Generating worst timing paths..."
report_timing -nworst 20 -file ../reports/synthesis/timing_worst_paths.txt

puts "Generating power estimate..."
report_power -file ../reports/synthesis/power_estimate.txt

puts "Generating design summary..."
report_design_analysis -file ../reports/synthesis/design_analysis.txt

# ---- Print Key Metrics to Console ----
puts ""
puts "================================================================"
puts "SYNTHESIS RESULTS"
puts "================================================================"

set timing_rpt [report_timing_summary -return_string]
if {[regexp {WNS\(ns\)\s+TNS\(ns\)\s+.*?\n\s*(-?[\d.]+)\s+(-?[\d.]+)} $timing_rpt match wns tns]} {
    puts "  Worst Negative Slack (WNS): $wns ns"
    puts "  Total Negative Slack (TNS): $tns ns"
    if {$wns >= 0} {
        set achieved_mhz [expr {1000.0 / ($clock_period - $wns)}]
        puts "  Timing Met: YES"
        puts "  Max Achievable Frequency: [format %.1f $achieved_mhz] MHz"
    } else {
        set achieved_mhz [expr {1000.0 / ($clock_period - $wns)}]
        puts "  Timing Met: NO"
        puts "  Current Achievable Frequency: [format %.1f $achieved_mhz] MHz"
    }
}

set util_rpt [report_utilization -return_string]
puts ""
puts "  Resource Utilization (post-synthesis):"
puts "  See: reports/synthesis/utilization_report.txt"
puts "================================================================"
puts ""
puts "Reports saved to: reports/synthesis/"
puts "Next step: run implementation with 'scripts/impl.tcl'"

# ---- Optionally Run Implementation ----
# Uncomment below to also run place-and-route:
#
# opt_design
# place_design
# route_design
# report_utilization -file ../reports/implementation/utilization_post_route.txt
# report_timing_summary -file ../reports/implementation/timing_post_route.txt
# report_timing -nworst 20 -file ../reports/implementation/timing_worst_paths_post_route.txt
# write_bitstream -force ../output/fpga_hft_system.bit

close_project
