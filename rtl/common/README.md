# rtl/common/

Small shared modules used by more than one pipeline stage.

```
sync_2ff.v      2-flop synchronizer for a single-bit signal crossing into this clock domain
counter_sat.v   saturating up-counter (holds at max, never wraps) — used by every error/event counter
mdio_ctrl.v     one-shot JL2121(D) MDIO bring-up sequencer (docs/design_decisions.md D4, D9 -- read D9 first, the contract in docs/contracts/mdio_ctrl.md targets the wrong PHY)
```

Each has a self-checking testbench in `tb/` (`tb_sync_2ff.v`, `tb_counter_sat.v`,
`tb_mdio_ctrl.v`) runnable under Icarus (`iverilog -g2001 -Wall ...`). Only add a module
here once a second stage actually needs it; don't pre-build a utility library beyond that.
