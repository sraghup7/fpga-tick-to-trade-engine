# constraints/

XDC constraint files, split by purpose so each is reviewable on its own (`fpga_project_flow.md`
Stage 6):

```
tob_pins.xdc      physical pin/package constraints (RGMII, LEDs, keys, JTAG) — see
                  docs/refs/AX7035B_pinout_notes.md and the ALINX AX7035B user guide
tob_timing.xdc    clock definitions and timing exceptions
```

Nothing here yet. A path never checked here is a path the tool silently reports as passing —
constrain exactly what's real, and never write an exception you can't justify out loud.
