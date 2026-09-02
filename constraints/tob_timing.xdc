# Clock definitions and timing exceptions. S0 skeleton has one real clock;
# the RGMII rx_clk (which becomes the engine's single 125 MHz system clock,
# per docs/design_decisions.md) is added here once the MAC adapter lands (S2).

create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
