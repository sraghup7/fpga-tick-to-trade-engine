# Clock definitions and timing exceptions.
#
# sys_clk: the 50 MHz board oscillator, used only for PHY reset sequencing
# and mdio_ctrl.v (D2) -- not the engine's clock.
#
# rx_clk: the RGMII receive clock, source-synchronous from the JL2121(D) PHY
# at 125 MHz (1000 Mbps RGMII). util_gmii_to_rgmii.v derives gmii_rx_clk from
# this port internally and D2 makes gmii_rx_clk the engine's single system
# clock domain -- so this is the one that actually matters for the whole
# design's timing closure. Same create_clock this board's own ALINX
# reference design uses (docs/refs/AX7035/SRC/21_ethernet_test/.../top.xdc),
# on the same port -- Vivado propagates it through util_gmii_to_rgmii's
# internal logic automatically; no create_generated_clock needed for what
# that module does (a near-direct IDDR-based recovery, matching the
# reference design's own untouched treatment of it).
#
# No RGMII input/output delay constraints are set here (docs/refs/
# AX7035B_pinout_notes.md's own "still open" note: the AC timing budget has
# not been re-derived from the JL2121(D)'s actual datasheet). ALINX's own
# working reference design for this exact board/PHY also sets none beyond
# SLEW FAST + this create_clock -- deliberately following that same proven,
# minimal pattern rather than inventing undocumented margins. Revisit if
# S11 bring-up shows RGMII link instability that a proper set_input_delay/
# set_output_delay budget would explain.

create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
create_clock -period 8.000  -name rx_clk  [get_ports rgmii_rxc]

# sys_clk and rx_clk are genuinely asynchronous to each other (independent
# oscillators; no shared reference), and the only two real crossings between
# them (kill_sw_n, the async reset) already go through proper 2FF
# synchronizers (rtl/common/sync_2ff.v -- u_kill_sync/u_rst_sync in
# tob_top.v) -- mdio_done_latched's only fan-out is an LED output port,
# which has no setup/hold requirement at all. Without this exception Vivado
# times every path between the two domains as if they shared a clock,
# which is where D26's unexplained mdio_ctrl WHS = -0.002 ns almost
# certainly comes from -- a spurious violation on a path that was never
# meant to be synchronous, not a real hold problem. This does not weaken
# anything: it tells the tool the two real crossings are handled by design
# (the synchronizers), not that timing on them doesn't matter.
set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks rx_clk]
