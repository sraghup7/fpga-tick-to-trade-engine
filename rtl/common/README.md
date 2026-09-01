# rtl/common/

Small shared modules used by more than one pipeline stage (e.g. `sync_2ff.v` for a 2-flop
CDC synchronizer, `counter_sat.v` for a saturating counter). Nothing here yet — only add a
module here once a second stage actually needs it; don't pre-build a utility library.
