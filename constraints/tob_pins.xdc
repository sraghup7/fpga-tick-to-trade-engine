# Physical pin constraints. S0 skeleton covers sys_clk/rst_n/key/led only —
# RGMII/MDIO pins are added here once the MAC adapter lands (S2); see
# docs/design_decisions.md for the source of every pin below.
#
# Source: docs/refs/AX7035/SRC/02_key_test/key_test/constrs_1/new/key.xdc
# (ALINX AX7035B reference project — key/LED pinout is identical across all
# their example projects, cross-checked against the schematic in
# docs/refs/AX7035/SCH/SCH.pdf).

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
