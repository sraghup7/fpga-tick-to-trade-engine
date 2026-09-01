"""Deterministic synthetic market-data generator (ml_engineer_brief.md SS6).

Produces a sequence of book-update / trade-print / book-clear events for one
or more symbols, covering the scenarios listed in the brief:
  - balanced book, stable mid
  - bid depletion followed by a downward move
  - ask depletion followed by an upward move
  - wide spreads / low liquidity
  - high update-rate / volatile periods
  - spoof-like size changes (labeled as synthetic)
  - bursts, stale intervals, sequence gaps, malformed events

A fixed seed (config.SEED) must reproduce the exact same dataset -- this is a
hard requirement so ml_golden.py and train.py can be re-run and compared.

Event schema (one dict per event):
  seq          : int, monotonic sequence number across the whole stream
  symbol_id    : int
  type         : 'quote' | 'trade' | 'clear'
  bid, ask     : int (ticks)            -- present for 'quote'
  bid_qty      : int                     -- present for 'quote'
  ask_qty      : int                     -- present for 'quote'
  trade_side   : +1 (buy) or -1 (sell)  -- present for 'trade'
  gap          : bool                    -- True if this event follows a
                                            deliberately-dropped sequence number
"""
from __future__ import annotations

import numpy as np

import config


def _quote(seq, symbol_id, bid, ask, bid_qty, ask_qty, gap=False):
    return {
        "seq": seq,
        "symbol_id": symbol_id,
        "type": "quote",
        "bid": int(bid),
        "ask": int(ask),
        "bid_qty": int(bid_qty),
        "ask_qty": int(ask_qty),
        "gap": gap,
    }


def _trade(seq, symbol_id, side, gap=False):
    return {
        "seq": seq,
        "symbol_id": symbol_id,
        "type": "trade",
        "trade_side": int(side),
        "gap": gap,
    }


def _clear(seq, symbol_id, gap=False):
    return {"seq": seq, "symbol_id": symbol_id, "type": "clear", "gap": gap}


class _SeqCounter:
    """Monotonic sequence number generator that can drop numbers to simulate gaps."""

    def __init__(self, rng: np.random.Generator, gap_prob: float = 0.0):
        self._next = 0
        self._rng = rng
        self._gap_prob = gap_prob

    def next(self) -> tuple[int, bool]:
        gapped = False
        if self._gap_prob > 0 and self._rng.random() < self._gap_prob:
            self._next += 1  # burn a sequence number to create a visible gap
            gapped = True
        seq = self._next
        self._next += 1
        return seq, gapped


def _random_walk_scenario(
    rng: np.random.Generator,
    seqc: _SeqCounter,
    symbol_id: int,
    n_events: int,
    start_bid: int,
    start_spread: int,
    bid_qty: int,
    ask_qty: int,
    price_drift: float,
    qty_drift_bid: float,
    qty_drift_ask: float,
    trade_prob: float,
    gap_prob: float,
):
    """General-purpose scenario generator: a bounded random walk in price and
    size, with optional directional drift and interleaved trade prints.
    """
    events = []
    bid, spread = start_bid, start_spread
    bq, aq = bid_qty, ask_qty
    for _ in range(n_events):
        bid = max(1, bid + int(round(rng.normal(price_drift, 1.0))))
        spread = max(1, spread + int(rng.integers(-1, 2)))
        ask = bid + spread
        bq = max(0, bq + int(round(rng.normal(qty_drift_bid, 5.0))))
        aq = max(0, aq + int(round(rng.normal(qty_drift_ask, 5.0))))
        seq, gapped = seqc.next()
        events.append(_quote(seq, symbol_id, bid, ask, bq, aq, gap=gapped))
        if rng.random() < trade_prob:
            side = 1 if rng.random() < 0.5 else -1
            seq, gapped = seqc.next()
            events.append(_trade(seq, symbol_id, side, gap=gapped))
    return events


def _scenario_balanced(rng, seqc, symbol_id):
    return _random_walk_scenario(
        rng, seqc, symbol_id, n_events=200, start_bid=10_000, start_spread=2,
        bid_qty=500, ask_qty=500, price_drift=0.0, qty_drift_bid=0.0,
        qty_drift_ask=0.0, trade_prob=0.05, gap_prob=0.0,
    )


def _scenario_bid_depletion(rng, seqc, symbol_id):
    """Bid size drains steadily; price should drift down as liquidity leaves."""
    return _random_walk_scenario(
        rng, seqc, symbol_id, n_events=150, start_bid=10_000, start_spread=2,
        bid_qty=800, ask_qty=500, price_drift=-0.15, qty_drift_bid=-4.0,
        qty_drift_ask=0.0, trade_prob=0.08, gap_prob=0.0,
    )


def _scenario_ask_depletion(rng, seqc, symbol_id):
    """Ask size drains steadily; price should drift up as liquidity leaves."""
    return _random_walk_scenario(
        rng, seqc, symbol_id, n_events=150, start_bid=10_000, start_spread=2,
        bid_qty=500, ask_qty=800, price_drift=0.15, qty_drift_bid=0.0,
        qty_drift_ask=-4.0, trade_prob=0.08, gap_prob=0.0,
    )


def _scenario_wide_spread(rng, seqc, symbol_id):
    events = []
    bid, spread = 10_000, 20
    bq, aq = 50, 50
    for _ in range(120):
        bid = max(1, bid + int(rng.integers(-2, 3)))
        spread = max(10, spread + int(rng.integers(-2, 3)))
        ask = bid + spread
        bq = max(0, bq + int(rng.integers(-5, 6)))
        aq = max(0, aq + int(rng.integers(-5, 6)))
        seq, gapped = seqc.next()
        events.append(_quote(seq, symbol_id, bid, ask, bq, aq, gap=gapped))
    return events


def _scenario_high_volatility(rng, seqc, symbol_id):
    events = []
    bid, spread = 10_000, 2
    bq, aq = 500, 500
    for _ in range(200):
        bid = max(1, bid + int(round(rng.normal(0.0, 8.0))))
        spread = max(1, spread + int(rng.integers(-1, 2)))
        ask = bid + spread
        bq = max(0, bq + int(round(rng.normal(0.0, 40.0))))
        aq = max(0, aq + int(round(rng.normal(0.0, 40.0))))
        seq, gapped = seqc.next()
        events.append(_quote(seq, symbol_id, bid, ask, bq, aq, gap=gapped))
        if rng.random() < 0.20:
            side = 1 if rng.random() < 0.5 else -1
            seq, gapped = seqc.next()
            events.append(_trade(seq, symbol_id, side, gap=gapped))
    return events


def _scenario_spoof_like(rng, seqc, symbol_id):
    """Large size appears then vanishes without a corresponding trade or price
    move -- a synthetic stand-in for spoofing, explicitly labeled as such."""
    events = []
    bid, spread = 10_000, 2
    bq, aq = 500, 500
    for i in range(160):
        if i % 40 == 20:
            bq += 5000  # sudden large size appears
        elif i % 40 == 25:
            bq = max(0, bq - 5000)  # then vanishes
        bid = max(1, bid + int(rng.integers(-1, 2)))
        ask = bid + spread
        seq, gapped = seqc.next()
        events.append(_quote(seq, symbol_id, bid, ask, bq, aq, gap=gapped))
    return events


def _scenario_bursty_gappy(rng, seqc, symbol_id):
    """Bursts of rapid updates interleaved with stale (unchanged) intervals,
    plus deliberately dropped sequence numbers."""
    events = []
    bid, spread = 10_000, 2
    bq, aq = 500, 500
    for i in range(180):
        burst = (i // 20) % 2 == 0
        if burst:
            bid = max(1, bid + int(round(rng.normal(0.0, 3.0))))
            bq = max(0, bq + int(round(rng.normal(0.0, 15.0))))
            aq = max(0, aq + int(round(rng.normal(0.0, 15.0))))
        ask = bid + spread
        seq, gapped = seqc.next()
        events.append(_quote(seq, symbol_id, bid, ask, bq, aq, gap=gapped))
    return events


_SCENARIOS = [
    _scenario_balanced,
    _scenario_bid_depletion,
    _scenario_ask_depletion,
    _scenario_wide_spread,
    _scenario_high_volatility,
    _scenario_spoof_like,
    _scenario_bursty_gappy,
]


def generate_dataset(seed: int = config.SEED, gap_prob: float = 0.01) -> list[dict]:
    """Generate the full deterministic synthetic dataset.

    Each scenario runs on its own symbol_id and is preceded by a 'clear' event
    so feature/label state never leaks across scenario boundaries.
    """
    rng = np.random.default_rng(seed)
    seqc = _SeqCounter(rng, gap_prob=gap_prob)
    events: list[dict] = []
    for symbol_id, scenario_fn in enumerate(_SCENARIOS):
        seq, gapped = seqc.next()
        events.append(_clear(seq, symbol_id, gap=gapped))
        events.extend(scenario_fn(rng, seqc, symbol_id))
    return events


if __name__ == "__main__":
    data = generate_dataset()
    n_quote = sum(1 for e in data if e["type"] == "quote")
    n_trade = sum(1 for e in data if e["type"] == "trade")
    n_clear = sum(1 for e in data if e["type"] == "clear")
    n_gap = sum(1 for e in data if e["gap"])
    print(f"seed={config.SEED} total_events={len(data)} quotes={n_quote} "
          f"trades={n_trade} clears={n_clear} gaps={n_gap}")
    print("first 5 events:")
    for e in data[:5]:
        print(" ", e)
