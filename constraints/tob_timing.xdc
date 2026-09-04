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
