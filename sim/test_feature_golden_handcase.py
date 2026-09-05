"""sim/test_feature_golden_handcase.py

Hand-computed check for sim/feature_golden.py (D13's window semantics),
same spirit as sim/test_golden_model_handcase.py: every expected value below
is computed by hand in the comment above its assertion, not copied from a
model run. Seven steps, window=4 (deliberately small so the window-rollover
and clear-reset behavior are exercised, not just steady-state). Step 7 was
added after the S3 implementation flagged that steps 1-6 (as originally
written) never exercised the event *after* a CLEAR, which is exactly the
case where this file's own reset()-then-tail-write behavior is easy to
misread from prose alone -- see docs/design_decisions.md D13's note and
docs/contracts/feature_extractor.md S2.3.

Run: python sim/test_feature_golden_handcase.py
"""

from feature_golden import FeatureTracker, MSG_CLEAR, MSG_QUOTE, SIDE_ASK

failures = []


def check(label, actual, expected):
    if actual != expected:
        failures.append(f"{label}: got {actual!r}, expected {expected!r}")


t = FeatureTracker(window=4)
SYM = 1

# Step 1: QUOTE bid=100/10, ask still unquoted (0/invalid). First event for
# this symbol -> f1=f3=f4=0. f0 = ask(0) - bid(100) = -100, saturates to 0
# (unsigned raw feature, never negative -- a real consequence of "no
# masking here", worth exercising explicitly). f2 = 10 - 0 = 10.
# window after: [(T,0)]. f5=1 (1/1 updates), f7=0.
fv = t.on_book_event(SYM, MSG_QUOTE, bid_price=100, bid_qty=10, bid_valid=True,
                      ask_price=0, ask_qty=0, ask_valid=False)
check("s1", fv.as_tuple(), (0, 0, 10, 0, 0, 1, 0, 0))

# Step 2: QUOTE ask=110/5 added (bid unchanged 100/10).
# mid=(100+110)>>1=105, prev_mid=(100+0)>>1=50 -> f1=55.
# f3 = bid_qty(10)-prev_bid_qty(10) = 0. f4 = ask_qty(5)-prev_ask_qty(0) = 5.
# f0 = 110-100=10. f2 = 10-5=5.
# window after: [(T,0),(T,55)]. f5=2, f7=0+55=55.
fv = t.on_book_event(SYM, MSG_QUOTE, bid_price=100, bid_qty=10, bid_valid=True,
                      ask_price=110, ask_qty=5, ask_valid=True)
check("s2", fv.as_tuple(), (10, 55, 5, 0, 5, 2, 0, 55))

# Step 3: TRADE, aggressor side=ASK (a sell) -> F6 becomes -1. No feature
# vector produced. Window gets a (False, 0) slot: [(T,0),(T,55),(F,0)].
t.on_trade(SYM, SIDE_ASK)

# Step 4: HEARTBEAT -> another (False, 0) slot, still no feature vector.
# window now exactly 4 deep: [(T,0),(T,55),(F,0),(F,0)].
t.on_heartbeat(SYM)

# Step 5: QUOTE bid=102/8 (ask unchanged 110/5).
# mid=(102+110)>>1=106, prev_mid=(100+110)>>1=105 -> f1=1.
# f3 = 8-10=-2. f4 = 5-5=0. f0=110-102=8. f2=8-5=3.
# window after append: [(T,0),(T,55),(F,0),(F,0),(T,1)] (5 stored, maxlen 32).
# active (last 4, window=4) = [(T,55),(F,0),(F,0),(T,1)] -> f5=2 (2 True),
# f7=55+0+0+1=56. f6 still -1 (from step 3's trade).
fv = t.on_book_event(SYM, MSG_QUOTE, bid_price=102, bid_qty=8, bid_valid=True,
                      ask_price=110, ask_qty=5, ask_valid=True)
check("s5", fv.as_tuple(), (8, 1, 3, -2, 0, 2, -1, 56))

# Step 6: CLEAR. D13: reset (prev_*, window, last_trade_dir all -> 0) THEN
# treated as "first event after reset" -- f1=f3=f4=0, f6 back to 0 (not -1).
# Book after clear (per golden_model.py's MSG_CLEAR: valid bits cleared,
# price/qty left stale, not zeroed) -- pass the stale values through
# mechanically (FR-26 masking is explicitly out of scope here):
# bid_price=102, bid_qty=8, ask_price=110, ask_qty=5, both invalid.
# f0 = 110-102=8. f2 = 8-5=3. window after reset+append: [(T,0)] -> f5=1, f7=0.
fv = t.on_book_event(SYM, MSG_CLEAR, bid_price=102, bid_qty=8, bid_valid=False,
                      ask_price=110, ask_qty=5, ask_valid=False)
check("s6", fv.as_tuple(), (8, 0, 3, 0, 0, 1, 0, 0))

# Step 7: QUOTE bid=105/12 (ask unchanged 110/5), the event RIGHT AFTER the
# clear. This is the case worth being explicit about: reset() zeroed
# prev_bid/prev_ask/prev_bid_qty/prev_ask_qty DURING step 6's own
# processing (so step 6 itself got the first-event F1=F3=F4=0 treatment),
# but on_book_event's unconditional tail write then set them to step 6's
# own (bid_price=102, ask_price=110, bid_qty=8, ask_qty=5) arguments -- the
# STALE, pre-clear book state (tob_engine.v's CLEAR doesn't zero price/qty,
# only valid bits). So THIS step is NOT a first event (seen_first_event was
# set True in step 6) and computes a REAL delta against that stale
# baseline, not against 0:
# mid=(105+110)>>1=107, prev_mid=(102+110)>>1=106 -> f1=1.
# f3 = bid_qty(12)-prev_bid_qty(8)=4. f4 = ask_qty(5)-prev_ask_qty(5)=0.
# f0=110-105=5. f2=12-5=7.
# window after step 6 was [(T,0)] (reset then step 6's own push); append
# (T, abs(1)=1) -> [(T,0),(T,1)] -> f5=2, f7=0+1=1. f6 still 0 (cleared at
# step 6, no trade since).
fv = t.on_book_event(SYM, MSG_QUOTE, bid_price=105, bid_qty=12, bid_valid=True,
                      ask_price=110, ask_qty=5, ask_valid=True)
check("s7", fv.as_tuple(), (5, 1, 7, 4, 0, 2, 0, 1))

if failures:
    print(f"FAIL ({len(failures)} mismatch(es)):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)

print("PASS: hand-computed feature-window case matches feature_golden.py exactly")
