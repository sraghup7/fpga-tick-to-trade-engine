"""sim/test_golden_model_handcase.py

The S1 milestone gate (master spec S15): "golden models produce expected
output for a hand-computed 20-message case." Now 25 messages (the original
20, plus 3 for D12's filter-vs-type/flags ordering fix and 2 for D14's
FR-15 price-preservation fix -- see docs/design_decisions.md) plus 2
control-plane actions (kill switch assert/clear, not messages). Every
expected value below is computed by hand in the comment above the
assertion, not derived by running the model and copying its output --
that would just confirm the model agrees with itself.

This case did its job once already: the first version of golden_model.py
ran the symbol filter before sequence-gap tracking, so message 3 (an
unwatched symbol) silently consumed a seq_num slot, and message 4 looked
like it arrived after a gap that never happened. Fixed by moving sequence
tracking before filtering (see the comment in golden_model.py's
process_message) -- exactly the kind of spec ambiguity master spec S11.1
says writing the model from the spec is supposed to surface.

Default Config: watched symbols {1,2,3,4}, min_spread=2, imb_shift=1,
order_qty=100, max_order_qty=500, max_position=1000, price_band=50,
token_max=8, token_refill_cycles=12500 (never reached in this short case,
so no refill arithmetic below). One shared seq_num sequence across symbols
(FR-10: "per feed", not per-symbol).

Run: python sim/test_golden_model_handcase.py
"""

from golden_model import (
    GATE_BAND,
    GATE_KILL,
    GATE_SEQGAP,
    GATE_STALE,
    FLAG_SNAPSHOT,
    Config,
    GoldenModel,
    Message,
    MSG_CLEAR,
    MSG_HEARTBEAT,
    MSG_QUOTE,
    MSG_TRADE,
    ORDER_MSG_NEW,
    ORDER_MSG_REJECT,
    SIDE_ASK,
    SIDE_BID,
)

failures = []


def check(label, actual, expected):
    if actual != expected:
        failures.append(f"{label}: got {actual!r}, expected {expected!r}")


def msg(seq, symbol, mtype, side=0, flags=0, price=0, qty=0):
    return Message(mtype, symbol, side, flags, price, qty, seq).encode()


# cfg_reject_report=True so this test can assert on reject_reason values
# (FR-44's own default is False -- reject frames are opt-in diagnostics;
# see D7. Turning it on here just makes the hand-check more thorough).
m = GoldenModel(Config(cfg_reject_report=True))

# 1. seq=100 QUOTE bid 1000/50 sym1
#    book1: bid=1000/50 valid, ask invalid -> no signal (ask invalid)
r = m.process_message(msg(100, 1, MSG_QUOTE, SIDE_BID, price=1000, qty=50))
check("m1 order", r.order, None)
check("m1 signal", r.signal_fired, None)

# 2. seq=101 QUOTE ask 1010/10 sym1
#    book1: bid=1000/50, ask=1010/10. spread=10>=2.
#    bid_qty(50) > ask_qty(10)<<1=20 -> BUY. price=ask=1010, qty=100(order_qty).
#    gates: kill=F, size 100<=500 ok, position 0+100=100<=1000 ok,
#      band: mid=(1000+1010)>>1=1005, |1010-1005|=5<=50 ok,
#      stale ok (fresh), seqgap F, crossed F, throttle token 8>0 ok, ML F.
#    -> ACCEPTED. position1=100, token=7, orders_tx=1.
r = m.process_message(msg(101, 1, MSG_QUOTE, SIDE_ASK, price=1010, qty=10))
check("m2 signal", r.signal_fired, "buy")
check("m2 order.msg_type", r.order.msg_type, ORDER_MSG_NEW)
check("m2 order.price", r.order.price, 1010)
check("m2 order.reject_reason", r.order.reject_reason, 0)
check("m2 position1", m.position[1], 100)
check("m2 token", m.token_bucket, 7)

# 3. seq=102 sym=99 (unwatched) -> filtered, no state change.
r = m.process_message(msg(102, 99, MSG_QUOTE, SIDE_BID, price=1, qty=1))
check("m3 order", r.order, None)
check("m3 cnt_msgs_filtered", m.counters["cnt_msgs_filtered"], 1)

# 4. seq=103 QUOTE bid 1002/5 sym1
#    book1: bid=1002/5, ask=1010/10 (unchanged). spread=8>=2.
#    bid_qty(5)>ask_qty(10)<<1=20? no. ask_qty(10)>bid_qty(5)<<1=10? no (not >).
#    -> no signal.
r = m.process_message(msg(103, 1, MSG_QUOTE, SIDE_BID, price=1002, qty=5))
check("m4 signal", r.signal_fired, None)

# 5. seq=104 TRADE side=ASK sym1 -> book price/qty unchanged, not
#    book-modifying (TRADE), cnt_trades+=1, no signal.
r = m.process_message(msg(104, 1, MSG_TRADE, SIDE_ASK, price=1010, qty=3))
check("m5 signal", r.signal_fired, None)
check("m5 cnt_trades", m.counters["cnt_trades"], 1)
check("m5 book unchanged", (m.books[1].bid_price, m.books[1].ask_price), (1002, 1010))

# 6. seq=106 (skips 105!) QUOTE ask 1005/50 sym1
#    expected was 105, got 106 -> gap=1, cnt_seq_gap+=1, seq_gap=True (sticky)
#    book1: bid=1002/5, ask=1005/50. not crossed (1002<1005). spread=3>=2.
#    bid_qty(5)>ask_qty(50)<<1=100? no. ask_qty(50)>bid_qty(5)<<1=10? yes -> SELL.
#    price=bid=1002, qty=100. gates: seq_gap=True -> GATE_SEQGAP fires (only one).
#    -> BLOCKED, reject_reason=6. position1 unchanged (100). token unchanged (7).
r = m.process_message(msg(106, 1, MSG_QUOTE, SIDE_ASK, price=1005, qty=50))
check("m6 cnt_seq_gap", m.counters["cnt_seq_gap"], 1)
check("m6 seq_gap sticky", m.seq_gap, True)
check("m6 signal", r.signal_fired, "sell")
check("m6 order.msg_type", r.order.msg_type, ORDER_MSG_REJECT)
check("m6 order.reject_reason", r.order.reject_reason, GATE_SEQGAP)
check("m6 position1 unchanged", m.position[1], 100)
check("m6 token unchanged", m.token_bucket, 7)

# 7. seq=107 CLEAR sym1 -> both sides invalid, cnt_book_clear+=1.
r = m.process_message(msg(107, 1, MSG_CLEAR))
check("m7 bid_valid", m.books[1].bid_valid, False)
check("m7 ask_valid", m.books[1].ask_valid, False)
check("m7 cnt_book_clear", m.counters["cnt_book_clear"], 1)

# 8. seq=108 QUOTE bid 2000/200 sym1, flags=SNAPSHOT -> clears sticky seq_gap.
#    ask still invalid (cleared in m7) -> no signal.
r = m.process_message(msg(108, 1, MSG_QUOTE, SIDE_BID, flags=FLAG_SNAPSHOT, price=2000, qty=200))
check("m8 seq_gap cleared", m.seq_gap, False)
check("m8 signal", r.signal_fired, None)

# 9. seq=109 QUOTE ask 2050/20 sym1
#    book1: bid=2000/200, ask=2050/20. spread=50>=2.
#    bid_qty(200)>ask_qty(20)<<1=40 -> BUY. price=ask=2050, qty=100.
#    gates: seq_gap now False (cleared m8) -> not fired. band: mid=(2000+2050)>>1=2025,
#      |2050-2025|=25<=50 ok. position 100+100=200<=1000 ok. throttle token=7>0 ok.
#    -> ACCEPTED. position1=200, token=6, orders_tx=2.
r = m.process_message(msg(109, 1, MSG_QUOTE, SIDE_ASK, price=2050, qty=20))
check("m9 order.msg_type", r.order.msg_type, ORDER_MSG_NEW)
check("m9 position1", m.position[1], 200)
check("m9 token", m.token_bucket, 6)
check("m9 cnt_orders_tx", m.counters["cnt_orders_tx"], 2)

# 10. seq=110 HEARTBEAT sym1 -> refreshes staleness only, cnt_heartbeats+=1,
#     not book-modifying -> no signal.
r = m.process_message(msg(110, 1, MSG_HEARTBEAT))
check("m10 signal", r.signal_fired, None)
check("m10 cnt_heartbeats", m.counters["cnt_heartbeats"], 1)

# 11. seq=111 QUOTE bid 2100/500 sym1
#     book1: bid=2100/500, ask=2050/20 (unchanged) -> CROSSED (2100>=2050).
#     cnt_crossed+=1. buy_ok/sell_ok both require `not crossed` -> no signal.
r = m.process_message(msg(111, 1, MSG_QUOTE, SIDE_BID, price=2100, qty=500))
check("m11 crossed", m.books[1].crossed, True)
check("m11 cnt_crossed", m.counters["cnt_crossed"], 1)
check("m11 signal", r.signal_fired, None)

# 12. seq=112 QUOTE ask 2200/15 sym1 -> uncrosses (2100<2200).
#     book1: bid=2100/500, ask=2200/15. spread=100>=2.
#     bid_qty(500)>ask_qty(15)<<1=30 -> BUY. price=ask=2200, qty=100.
#     gates: band: mid=(2100+2200)>>1=2150, |2200-2150|=50 -- NOT > 50 (boundary,
#       spec condition is strictly >) -> not fired. position 200+100=300<=1000 ok.
#       throttle token=6>0 ok.
#     -> ACCEPTED. position1=300, token=5, orders_tx=3.
r = m.process_message(msg(112, 1, MSG_QUOTE, SIDE_ASK, price=2200, qty=15))
check("m12 order.msg_type", r.order.msg_type, ORDER_MSG_NEW)
check("m12 position1", m.position[1], 300)
check("m12 token", m.token_bucket, 5)

# 13. seq=113 QUOTE bid 1000/1000 sym1
#     book1: bid=1000/1000, ask=2200/15 (unchanged). spread=1200>=2.
#     bid_qty(1000)>ask_qty(15)<<1=30 -> BUY. price=ask=2200, qty=100.
#     gates: band: mid=(1000+2200)>>1=1600, |2200-1600|=600>50 -> GATE_BAND fires.
#       position 300+100=400<=1000 ok (not fired; band is the only gate).
#     -> BLOCKED, reject_reason=4. position1 unchanged (300). token unchanged (5).
r = m.process_message(msg(113, 1, MSG_QUOTE, SIDE_BID, price=1000, qty=1000))
check("m13 order.msg_type", r.order.msg_type, ORDER_MSG_REJECT)
check("m13 order.reject_reason", r.order.reject_reason, GATE_BAND)
check("m13 position1 unchanged", m.position[1], 300)

# 14. seq=113 again (duplicate -- expected_seq is now 114) -> dropped before
#     any book/signal processing; book must be untouched.
r = m.process_message(msg(113, 1, MSG_QUOTE, SIDE_BID, price=9999, qty=1))
check("m14 order", r.order, None)
check("m14 signal", r.signal_fired, None)
check("m14 cnt_seq_dup", m.counters["cnt_seq_dup"], 1)
check("m14 book bid unchanged", m.books[1].bid_price, 1000)

# 15. [control] kill switch asserted (FR-46) -- not a message.
m.assert_kill_switch()

# 16. seq=114 QUOTE ask 1010/8 sym1
#     book1: bid=1000/1000, ask=1010/8. spread=10>=2.
#     bid_qty(1000)>ask_qty(8)<<1=16 -> BUY. price=ask=1010, qty=100.
#     gates: kill_latched=True -> GATE_KILL fires (dominates; band would also
#       pass here: mid=(1000+1010)>>1=1005, |1010-1005|=5<=50, not fired anyway).
#     -> BLOCKED, reject_reason=1. position1 unchanged (300).
r = m.process_message(msg(114, 1, MSG_QUOTE, SIDE_ASK, price=1010, qty=8))
check("m16 order.reject_reason", r.order.reject_reason, GATE_KILL)
check("m16 position1 unchanged", m.position[1], 300)

# 17. [control] kill switch cleared -- not a message.
m.clear_kill_switch()

# 18. seq=115 QUOTE bid 1002/3 sym1
#     book1: bid=1002/3, ask=1010/8 (unchanged). spread=8>=2.
#     bid_qty(3)>ask_qty(8)<<1=16? no. ask_qty(8)>bid_qty(3)<<1=6? yes -> SELL.
#     price=bid=1002, qty=100. gates: kill now False. position: signed=-100,
#       300-100=200<=1000 ok. band: mid=(1002+1010)>>1=1006, |1002-1006|=4<=50 ok.
#       throttle token=5>0 ok.
#     -> ACCEPTED. position1=200, token=4, orders_tx=4.
r = m.process_message(msg(115, 1, MSG_QUOTE, SIDE_BID, price=1002, qty=3))
check("m18 signal", r.signal_fired, "sell")
check("m18 order.msg_type", r.order.msg_type, ORDER_MSG_NEW)
check("m18 position1", m.position[1], 200)
check("m18 token", m.token_bucket, 4)
check("m18 cnt_orders_tx", m.counters["cnt_orders_tx"], 4)

# 19. seq=116 QUOTE bid 500/10 sym2 (independent book; shared seq sequence
#     continues from 116 regardless of symbol -- FR-10 "per feed").
#     book2: bid=500/10, ask invalid -> no signal.
r = m.process_message(msg(116, 2, MSG_QUOTE, SIDE_BID, price=500, qty=10))
check("m19 signal", r.signal_fired, None)

# 20. seq=117 QUOTE ask 520/3 sym2
#     book2: bid=500/10, ask=520/3. spread=20>=2.
#     bid_qty(10)>ask_qty(3)<<1=6 -> BUY. price=ask=520, qty=100.
#     gates: position2 0+100=100<=1000 ok. band: mid=(500+520)>>1=510,
#       |520-510|=10<=50 ok. throttle token=4>0 ok (shared bucket across symbols).
#     -> ACCEPTED. position2=100, token=3, orders_tx=5.
r = m.process_message(msg(117, 2, MSG_QUOTE, SIDE_ASK, price=520, qty=3))
check("m20 order.msg_type", r.order.msg_type, ORDER_MSG_NEW)
check("m20 position2", m.position[2], 100)
check("m20 token", m.token_bucket, 3)
check("m20 cnt_orders_tx", m.counters["cnt_orders_tx"], 5)

# 19. seq=118 sym1, msg_type=0x05 (undefined) -> err_msg_type+=1 (FR-8).
#     Seq tracking still runs first (expected=118, matches) -> expected=119.
r = m.process_message(msg(118, 1, 0x05))
check("m19 err_msg_type", m.counters["err_msg_type"], 1)
check("m19 order", r.order, None)

# 20. seq=119 sym1, QUOTE with reserved flag bit7 set -> err_flags+=1 (FR-9).
#     Seq tracking still runs first (expected=119, matches) -> expected=120.
r = m.process_message(msg(119, 1, MSG_QUOTE, SIDE_BID, flags=0x80, price=1, qty=1))
check("m20b err_flags", m.counters["err_flags"], 1)
check("m20b order", r.order, None)

# 21. seq=120 sym=99 (unwatched) AND msg_type=0x05 (undefined), both at once.
#     D12: msg_type/flags is checked before the symbol filter (md_parser.v
#     already drops this upstream of symbol_filter.v in the real pipeline)
#     -> err_msg_type+=1, NOT cnt_msgs_filtered. Before D12's reorder this
#     assertion would have failed (old code checked filter first and would
#     have reported cnt_msgs_filtered instead).
r = m.process_message(msg(120, 99, 0x05))
check("m21 err_msg_type (not filtered)", m.counters["err_msg_type"], 2)
check("m21 cnt_msgs_filtered unchanged", m.counters["cnt_msgs_filtered"], 1)
check("m21 order", r.order, None)

# 22. seq=121 sym=99 (unwatched) AND reserved flag bit7 set, both at once.
#     Same reasoning as m21: err_flags+=1, NOT cnt_msgs_filtered.
r = m.process_message(msg(121, 99, MSG_QUOTE, SIDE_BID, flags=0x80, price=1, qty=1))
check("m22 err_flags (not filtered)", m.counters["err_flags"], 2)
check("m22 cnt_msgs_filtered unchanged", m.counters["cnt_msgs_filtered"], 1)
check("m22 order", r.order, None)

# 23. seq=122 sym=99 (unwatched), well-formed type/flags -> filtered, as
#     before -- confirms D12 only reorders the *simultaneous* bad case,
#     not plain filtering.
r = m.process_message(msg(122, 99, MSG_QUOTE, SIDE_BID, price=1, qty=1))
check("m23 cnt_msgs_filtered", m.counters["cnt_msgs_filtered"], 2)
check("m23 order", r.order, None)

# 24. seq=123 sym2, QUOTE bid qty=0 with a garbage price (9999) -- D14:
#     FR-15's "clears validity without altering stored price" means the
#     price write itself is skipped when qty=0, not just that valid is
#     cleared. book2.bid_price was set to 500 by message 19 and must still
#     read 500 afterward, not 9999. bid_qty must read 0, bid_valid False.
r = m.process_message(msg(123, 2, MSG_QUOTE, SIDE_BID, price=9999, qty=0))
check("m24 bid_price unchanged (D14)", m.books[2].bid_price, 500)
check("m24 bid_qty cleared", m.books[2].bid_qty, 0)
check("m24 bid_valid cleared", m.books[2].bid_valid, False)
check("m24 signal (bid invalid)", r.signal_fired, None)

# 25. seq=124 sym2, QUOTE bid price=505/qty=7 (side revalidated normally --
#     confirms D14's conditional-price-write didn't break the ordinary
#     FR-14 path, only the qty=0 case).
#     book2 now: bid=505/7, ask=520/3 (unchanged since m20). spread=15>=2.
#     bid_qty(7)>ask_qty(3)<<1=6 -> BUY. price=ask=520, qty=100.
#     gates: kill=F (cleared since m17). size 100<=500 ok.
#       position2: 100(from m20)+100=200<=1000 ok.
#       band: mid=(505+520)>>1=512, |520-512|=8<=50 ok.
#       stale ok (fresh). seqgap F (cleared since m8, no gap since). crossed F.
#       throttle: token=3 (after m2,m9,m12,m18,m20 each -1 from 8) >0 ok. ML F.
#     -> ACCEPTED. position2=200, token=2, cnt_orders_tx=6.
r = m.process_message(msg(124, 2, MSG_QUOTE, SIDE_BID, price=505, qty=7))
check("m25 bid_price updated", m.books[2].bid_price, 505)
check("m25 bid_qty updated", m.books[2].bid_qty, 7)
check("m25 bid_valid set", m.books[2].bid_valid, True)
check("m25 signal", r.signal_fired, "buy")
check("m25 order.msg_type", r.order.msg_type, ORDER_MSG_NEW)
check("m25 position2", m.position[2], 200)
check("m25 token", m.token_bucket, 2)
check("m25 cnt_orders_tx", m.counters["cnt_orders_tx"], 6)

# -- final invariant check (master spec S10): --
# cnt_signal_buy + cnt_signal_sell = cnt_orders_tx + sum(cnt_rej_*) + cnt_order_overflow
# Signals fired: m2(buy) m6(sell) m9(buy) m12(buy) m13(buy) m16(buy) m18(sell)
#                m20(buy) m25(buy) = 9
# Orders_tx (accepted): m2,m9,m12,m18,m20,m25 = 6
# Rejects: m6(seqgap) m13(band) m16(kill) = 3
# Overflow: 0
check("cnt_signal_buy", m.counters["cnt_signal_buy"], 7)
check("cnt_signal_sell", m.counters["cnt_signal_sell"], 2)
check(
    "invariant: signals == orders + rejects + overflow",
    m.counters["cnt_signal_buy"] + m.counters["cnt_signal_sell"],
    m.counters["cnt_orders_tx"]
    + m.counters["cnt_rej_seqgap"]
    + m.counters["cnt_rej_band"]
    + m.counters["cnt_rej_kill"]
    + m.counters["cnt_order_overflow"],
)
check("cnt_msgs_rx", m.counters["cnt_msgs_rx"], 25)
check(
    "invariant: msgs_rx == filtered + accepted + err_msg_type + err_flags",
    m.counters["cnt_msgs_rx"],
    m.counters["cnt_msgs_filtered"]
    + m.counters["cnt_msgs_accepted"]
    + m.counters["err_msg_type"]
    + m.counters["err_flags"],
)

# ============================================================================
# D16 regression: gate 0x09's ml_action=1 (reduce) path. Separate model
# instance/config (ml_action=1, ml_reduce_shift=1) -- not part of the
# 25-message default-config narrative above. Before D16, `position` was
# updated by the pre-reduction order_qty (100) even though the emitted
# order and the ledger disagreed about how many shares actually traded;
# fixed to use reduced_qty (order_qty >> ml_reduce_shift = 50) for the
# position update specifically, while gate 0x03's own admission check still
# uses the unreduced order_qty (FR-48: ML reduction is gate 0x09's own
# action, independent of gates 0x01-0x08's evaluation -- this is
# deliberately NOT "fixed" to also use reduced_qty).
m2 = GoldenModel(Config(cfg_reject_report=True, ml_action=1, ml_reduce_shift=1))

# n1: seq=1 QUOTE bid 1000/50 sym1 -> book1 bid=1000/50, ask invalid, no signal.
m2.process_message(msg(1, 1, MSG_QUOTE, SIDE_BID, price=1000, qty=50))

# n2: seq=2 QUOTE ask 1010/10 sym1, adverse_risk=True.
#     book1: bid=1000/50, ask=1010/10. spread=10>=2. bid_qty(50)>ask_qty(10)<<1=20
#     -> BUY. price=ask=1010, order_qty=100(cfg.order_qty).
#     gates 0x01-0x08: none fire (kill=F, size 100<=500, position
#       0+100=100<=1000 [checked against UNREDUCED 100, not 50], band
#       mid=(1000+1010)>>1=1005 |1010-1005|=5<=50, stale ok, seqgap F,
#       crossed F, throttle token 8>0). ml_action=1 -> reduced_qty =
#       100>>1 = 50, GATE_ML does NOT fire (reduce, not block).
#     -> ACCEPTED. Reported order.quantity = 50 (reduced). Position update
#     uses the REDUCED signed qty (D16): position1 = 0 + 50 = 50, not 100.
r = m2.process_message(msg(2, 1, MSG_QUOTE, SIDE_ASK, price=1010, qty=10), adverse_risk=True)
check("n2 order.quantity (reduced)", r.order.quantity, 50)
check("n2 order.reject_reason (accepted)", r.order.reject_reason, 0x00)
check("n2 position1 (D16: reduced, not 100)", m2.position[1], 50)
check("n2 cnt_ml_adverse", m2.counters["cnt_ml_adverse"], 1)
check("n2 cnt_rej_ml (reduce, not a reject)", m2.counters["cnt_rej_ml"], 0)

# ============================================================================
# D17 regression: gate 0x05 (staleness) was UNREACHABLE via any normal
# message flow before this fix. book.last_update_cycle was overwritten to
# self.current_cycle at the top of every book-modifying message's
# processing, BEFORE the staleness check ran later in that same call --
# so "current_cycle - book.last_update_cycle" was always comparing a
# just-refreshed timestamp against itself (always 0), and GATE_STALE could
# never fire for any book-modifying message, ever, regardless of how long
# the symbol had actually been silent. T18_gate_stale (a REQUIRED S7 gate
# test) could not have passed against the unfixed model. Fixed by capturing
# `prev_update_cycle` BEFORE the message's own refresh, and checking THAT
# (not the just-overwritten book.last_update_cycle) against max_age.
# Separate model instance, small max_age=50 to make the arithmetic legible.
m3 = GoldenModel(Config(cfg_reject_report=True, max_age=50))

# n3: seq=1 QUOTE bid 1000/50 sym1 @ cycle 10 -> bid valid, ask invalid,
#     no signal (ask side still invalid). last_update_cycle1 = 10.
r = m3.process_message(msg(1, 1, MSG_QUOTE, SIDE_BID, price=1000, qty=50), arrival_cycle=10)
check("n3 signal", r.signal_fired, None)

# n4: seq=2 QUOTE ask 1010/10 sym1 @ cycle 20. book1: bid=1000/50,
#     ask=1010/10. spread=10>=2. bid_qty(50)>ask_qty(10)<<1=20 -> BUY.
#     gap since n3's touch = 20-10=10, not > max_age(50) -> STALE not fired.
#     -> ACCEPTED. last_update_cycle1 becomes 20.
r = m3.process_message(msg(2, 1, MSG_QUOTE, SIDE_ASK, price=1010, qty=10), arrival_cycle=20)
check("n4 order.reject_reason (fresh, accepted)", r.order.reject_reason, 0x00)

# n5 ("silence past MAX_AGE"): seq=3, same QUOTE resent @ cycle 1000 --
#     980 cycles since n4's touch (20), far past max_age=50. GATE_STALE
#     fires (D17: this is the case that was unreachable before the fix).
#     last_update_cycle1 becomes 1000 regardless of the reject (the
#     timestamp always refreshes on a book-modifying touch, per FR-19).
r = m3.process_message(msg(3, 1, MSG_QUOTE, SIDE_ASK, price=1010, qty=10), arrival_cycle=1000)
check("n5 order.reject_reason (D17: STALE)", r.order.reject_reason, GATE_STALE)

# n6 ("then fresh update"): seq=4, same QUOTE again @ cycle 1010 -- only 10
#     cycles since n5's touch (1000), not > max_age(50) -> accepted again,
#     confirming the block clears once the book is genuinely fresh.
r = m3.process_message(msg(4, 1, MSG_QUOTE, SIDE_ASK, price=1010, qty=10), arrival_cycle=1010)
check("n6 order.reject_reason (fresh again, accepted)", r.order.reject_reason, 0x00)

if failures:
    print(f"FAIL ({len(failures)} mismatch(es)):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)

print("PASS: hand-computed 25-message case matches the golden model exactly")
