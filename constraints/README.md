# constraints/

XDC constraint files, split by purpose so each is reviewable on its own (`fpga_project_flow.md`
Stage 6):

```
tob_pins.xdc      physical pin/package constraints (RGMII, LEDs, keys, JTAG) — see
                  docs/refs/AX7035B_pinout_notes.md and the ALINX AX7035B user guide
tob_timing.xdc    clock definitions and timing exceptions
```

`tob_pins.xdc` currently constrains only the S0 skeleton's `sys_clk`/`rst_n`/`led[3:0]`/
`key_in[3:0]` pins; `tob_timing.xdc` only `sys_clk`'s own 50 MHz. RGMII/MDIO pin constraints
and the recovered `gmii_rx_clk` timing definition (which becomes the engine's single 125 MHz
system clock per `docs/design_decisions.md` D2) are still not added, even though `eth_mac_if.v`
and the modules through `order_builder.v` are done in simulation (S2/S3/S5/S7/S8) — nothing
has driven adding them yet since synthesis hasn't started. Add them before S10 (integration/
timing closure), not before. A path never checked here is a path the tool silently reports as
passing — constrain exactly what's real, and never write an exception you can't justify out
loud.
