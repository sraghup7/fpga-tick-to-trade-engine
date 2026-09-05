# Physical pin constraints.
#
# sys_clk/rst_n/key/led source: docs/refs/AX7035/SRC/02_key_test/key_test/
# constrs_1/new/key.xdc (ALINX AX7035B reference project — key/LED pinout is
# identical across all their example projects, cross-checked against the
# schematic in docs/refs/AX7035/SCH/SCH.pdf).
#
# RGMII/MDIO/PHY-reset source: docs/refs/AX7035B_pinout_notes.md's pin table
# (all 15 pins confirmed against the real AX7035B_UG.pdf manual, pages
# 14-15, AND the schematic directly), cross-checked pin-for-pin against
# ALINX's own working reference design's XDC: docs/refs/AX7035/SRC/
# 21_ethernet_test/ethernet_test/rgmii_ethernet/eth_test.srcs/constrs_1/new/
# top.xdc (same board, same JL2121(D) PHY, same fifteen pins — every value
# below matches that file exactly, just renamed to tob_top.v's own port
# names). IOSTANDARD/SLEW also follow that reference: LVCMOS33 throughout
# (bank 15 is 3.3V per the pinout notes), SLEW FAST on the TX-side pins.

set_property PACKAGE_PIN Y18 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]

set_property PACKAGE_PIN F20 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

set_property PACKAGE_PIN F19 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN E21 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN D20 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN C20 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

# KEY1=M13 (kill switch), KEY2=K14 (counter/latch clear),
# KEY3=K13 (mode select, reserved), KEY4=L13 (spare) — see §17 resolution
# in the master spec and docs/design_decisions.md for the rationale.
set_property PACKAGE_PIN M13 [get_ports {key_in[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in[0]}]
set_property PACKAGE_PIN K14 [get_ports {key_in[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in[1]}]
set_property PACKAGE_PIN K13 [get_ports {key_in[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in[2]}]
set_property PACKAGE_PIN L13 [get_ports {key_in[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in[3]}]

# ---- RGMII (E1_* in the manual's own naming) ----
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_txd[*]}]
set_property SLEW FAST [get_ports {rgmii_txd[*]}]
set_property PACKAGE_PIN J21 [get_ports {rgmii_txd[0]}]   # E1_TXD0
set_property PACKAGE_PIN M20 [get_ports {rgmii_txd[1]}]   # E1_TXD1
set_property PACKAGE_PIN L18 [get_ports {rgmii_txd[2]}]   # E1_TXD2
set_property PACKAGE_PIN L20 [get_ports {rgmii_txd[3]}]   # E1_TXD3

set_property PACKAGE_PIN L19 [get_ports rgmii_tx_ctl]      # E1_TXEN
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_tx_ctl]
set_property SLEW FAST [get_ports rgmii_tx_ctl]

set_property PACKAGE_PIN L14 [get_ports rgmii_txc]         # E1_GTXC
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_txc]
set_property SLEW FAST [get_ports rgmii_txc]

set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_rxd[*]}]
set_property PACKAGE_PIN K19 [get_ports {rgmii_rxd[0]}]   # E1_RXD0
set_property PACKAGE_PIN M15 [get_ports {rgmii_rxd[1]}]   # E1_RXD1
set_property PACKAGE_PIN J17 [get_ports {rgmii_rxd[2]}]   # E1_RXD2
set_property PACKAGE_PIN J20 [get_ports {rgmii_rxd[3]}]   # E1_RXD3

set_property PACKAGE_PIN M21 [get_ports rgmii_rx_ctl]      # E1_RXDV
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rx_ctl]

set_property PACKAGE_PIN K18 [get_ports rgmii_rxc]         # E1_RXC
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rxc]

# ---- MDIO / PHY reset ----
set_property PACKAGE_PIN K17 [get_ports mdc]               # E1_MDC
set_property IOSTANDARD LVCMOS33 [get_ports mdc]
set_property PACKAGE_PIN K16 [get_ports mdio]               # E1_MDIO
set_property IOSTANDARD LVCMOS33 [get_ports mdio]
set_property PACKAGE_PIN L15 [get_ports phy_reset_n]       # E1_RESET
set_property IOSTANDARD LVCMOS33 [get_ports phy_reset_n]

# ---- Board-required config properties (ALINX reference top.xdc) ----
# Needed for a bootable/programmable bitstream on this specific board's SPI
# config flash and I/O bank behavior; harmless for pure JTAG-SRAM bring-up
# too, so set unconditionally rather than only once flashing is attempted.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
