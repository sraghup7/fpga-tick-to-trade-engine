"""sim/feed_gen.py

Parametric stimulus generator for the market-data feed (master spec S11.2).
Produces the exact wire format golden_model.py consumes (S4.3/S4.4), seeded
for reproducibility -- every generated file records its seed so a failure
is re-runnable from the seed alone (fpga_project_flow.md Stage 3).

Scenarios implemented:
  normal     well-formed random walk, both sides valid
  sparse     long inter-message gaps (staleness gate, 0x05)
  crossed    injects crossed books (0x07)
  gaps       drops/duplicates sequence numbers (0x06, cnt_seq_dup)
  malformed  bad lengths/types/flags (err_frame_len/err_msg_type/err_flags)
  burst      many messages packed per frame, minimal gaps (NFR-4)
  trigger    tuned to fire the buy/sell signal at a roughly known rate

Not implemented here: `adverse` (S11.2's scenario tuned to produce
adverse-selection labels at a known rate). That depends on the label
definition (S5.2), which is the ML collaborator's side of S1 -- freezing
it is explicitly a joint S1 gate item (master spec S15's S1 row: "Both").
Add it once that's frozen, not before.

CLI usage:
  python feed_gen.py --scenario normal --count 50 --seed 1 --out normal.hex
  python feed_gen.py --scenario gaps --count 30 --seed 2 --out gaps.hex

Output is one frame's payload bytes per line, hex-encoded (offline file
format per S11.2; a live-UDP-traffic mode can be layered on top of
`build_frame`/`iter_scenario` later without changing the generation logic).
"""

from __future__ import annotations

import argparse
import random
from dataclasses import dataclass
from typing import Iterator, Optional

from golden_model import (
    FLAG_RESERVED_MASK,
    FLAG_SNAPSHOT,
    Message,
    MSG_CLEAR,
    MSG_HEARTBEAT,
    MSG_QUOTE,
    MSG_TRADE,
    SIDE_ASK,
    SIDE_BID,
)


@dataclass
class Frame:
    """One generated frame: its payload bytes plus metadata a test harness
    needs to know what to expect (since `payload` alone doesn't say
    whether it was deliberately corrupted)."""

    payload: bytes
    description: str


def build_frame(messages: list[Message]) -> bytes:
    """Pack messages back-to-back, no padding (S4.4). Caller is responsible
    for keeping message count within 1-88 (FR-4) unless deliberately
    testing the boundary."""
    return b"".join(m.encode() for m in messages)


class FeedState:
    """Tracks per-symbol book state and the shared seq_num counter so
    generated messages are self-consistent (e.g. a QUOTE ask price is
    generated relative to the last known bid, not independently random --
    otherwise "normal" would mostly generate messages a real feed would
    never produce, like a random walk that's crossed most of the time)."""

    def __init__(self, rng: random.Random, symbols: tuple[int, ...]):
        self.rng = rng
        self.symbols = symbols
        self.seq = 1
        self.bid_price = {s: 10_000 for s in symbols}
        self.ask_price = {s: 10_010 for s in symbols}

    def next_seq(self) -> int:
        s = self.seq
        self.seq += 1
        return s

    def quote(self, symbol: int, side: int, flags: int = 0, seq: Optional[int] = None) -> Message:
        if side == SIDE_BID:
            price = self.bid_price[symbol] + self.rng.randint(-3, 3)
            self.bid_price[symbol] = price
        else:
            price = self.ask_price[symbol] + self.rng.randint(-3, 3)
            self.ask_price[symbol] = price
        qty = self.rng.randint(1, 200)
        return Message(
            MSG_QUOTE, symbol, side, flags, price, qty, self.next_seq() if seq is None else seq
        )


def iter_scenario(
    scenario: str, count: int, seed: int, symbols: tuple[int, ...] = (1, 2, 3, 4)
) -> Iterator[Frame]:
    rng = random.Random(seed)
    state = FeedState(rng, symbols)

    if scenario == "normal":
        yield from _normal(rng, state, count)
    elif scenario == "sparse":
        yield from _normal(rng, state, count)  # gap timing is a harness concern (arrival_cycle)
    elif scenario == "crossed":
        yield from _crossed(rng, state, count)
    elif scenario == "gaps":
        yield from _gaps(rng, state, count)
    elif scenario == "malformed":
        yield from _malformed(rng, state, count)
    elif scenario == "burst":
        yield from _burst(rng, state, count)
    elif scenario == "trigger":
        yield from _trigger(rng, state, count)
    else:
        raise ValueError(f"unknown scenario {scenario!r}")


def _normal(rng: random.Random, state: FeedState, count: int) -> Iterator[Frame]:
    for _ in range(count):
        symbol = rng.choice(state.symbols)
        side = rng.choice((SIDE_BID, SIDE_ASK))
        msg = state.quote(symbol, side)
        yield Frame(build_frame([msg]), f"normal quote sym={symbol} side={side}")


def _crossed(rng: random.Random, state: FeedState, count: int) -> Iterator[Frame]:
    for i in range(count):
        symbol = rng.choice(state.symbols)
        if i % 3 == 0:
            # Force the book crossed: bid above the current ask.
            price = state.ask_price[symbol] + rng.randint(1, 20)
            state.bid_price[symbol] = price
            msg = Message(MSG_QUOTE, symbol, SIDE_BID, 0, price, rng.randint(1, 100), state.next_seq())
            yield Frame(build_frame([msg]), f"crossed: forced bid>=ask sym={symbol}")
        else:
            msg = state.quote(symbol, rng.choice((SIDE_BID, SIDE_ASK)))
            yield Frame(build_frame([msg]), f"crossed filler sym={symbol}")


def _gaps(rng: random.Random, state: FeedState, count: int) -> Iterator[Frame]:
    for i in range(count):
        symbol = rng.choice(state.symbols)
        side = rng.choice((SIDE_BID, SIDE_ASK))
        if i > 0 and i % 4 == 0:
            # Skip ahead (gap) or step back (duplicate), alternating.
            if i % 8 == 0:
                state.seq += rng.randint(2, 5)  # gap
                msg = state.quote(symbol, side)
                yield Frame(build_frame([msg]), f"gaps: seq jump sym={symbol}")
            else:
                dup_seq = max(1, state.seq - rng.randint(1, 3))  # duplicate/reorder
                msg = state.quote(symbol, side, seq=dup_seq)
                yield Frame(build_frame([msg]), f"gaps: seq dup/reorder sym={symbol}")
        else:
            msg = state.quote(symbol, side)
            yield Frame(build_frame([msg]), f"gaps filler sym={symbol}")


def _malformed(rng: random.Random, state: FeedState, count: int) -> Iterator[Frame]:
    for i in range(count):
        kind = i % 3
        symbol = rng.choice(state.symbols)
        if kind == 0:
            # err_frame_len: payload length not a multiple of 16.
            good = state.quote(symbol, SIDE_BID).encode()
            yield Frame(good[:-3], f"malformed: truncated payload (bad length) sym={symbol}")
        elif kind == 1:
            # err_msg_type: undefined type.
            msg = Message(0x07, symbol, SIDE_BID, 0, 1, 1, state.next_seq())
            yield Frame(build_frame([msg]), f"malformed: undefined msg_type sym={symbol}")
        else:
            # err_flags: reserved bits set.
            msg = state.quote(symbol, SIDE_ASK, flags=FLAG_RESERVED_MASK & 0x40)
            yield Frame(build_frame([msg]), f"malformed: reserved flag bits set sym={symbol}")


def _burst(rng: random.Random, state: FeedState, count: int) -> Iterator[Frame]:
    # NFR-4: pack up to 88 messages per frame, minimal inter-frame gap is a
    # harness/timing concern -- this just maximizes messages per frame.
    remaining = count
    while remaining > 0:
        n = min(88, remaining)
        msgs = [state.quote(rng.choice(state.symbols), rng.choice((SIDE_BID, SIDE_ASK))) for _ in range(n)]
        msgs[-1].flags |= FLAG_SNAPSHOT if rng.random() < 0.1 else 0
        yield Frame(build_frame(msgs), f"burst: {n} messages packed")
        remaining -= n


def _trigger(rng: random.Random, state: FeedState, count: int) -> Iterator[Frame]:
    # Alternately widen the spread and skew size to reliably cross the
    # default min_spread=2/imb_shift=1 buy/sell thresholds (S6.6), then
    # relax back -- "fires the signal at a known rate" per S11.2, roughly
    # every 3rd frame here. Exact rate isn't spec'd; this is a starting
    # point to tune once T13/T14 exist and want a specific hit rate.
    for i in range(count):
        symbol = rng.choice(state.symbols)
        if i % 3 == 0:
            bid_price = state.ask_price[symbol] - rng.randint(5, 10)
            state.bid_price[symbol] = bid_price
            msg = Message(MSG_QUOTE, symbol, SIDE_BID, 0, bid_price, 500, state.next_seq())
            yield Frame(build_frame([msg]), f"trigger: skew bid qty sym={symbol}")
        else:
            msg = state.quote(symbol, rng.choice((SIDE_BID, SIDE_ASK)))
            yield Frame(build_frame([msg]), f"trigger filler sym={symbol}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", required=True,
                    choices=("normal", "sparse", "crossed", "gaps", "malformed", "burst", "trigger"))
    ap.add_argument("--count", type=int, default=50, help="number of frames to generate")
    ap.add_argument("--seed", type=int, required=True, help="recorded in the output header for reproducibility")
    ap.add_argument("--out", required=True, help="output hex file path")
    args = ap.parse_args()

    with open(args.out, "w") as f:
        f.write(f"# scenario={args.scenario} count={args.count} seed={args.seed}\n")
        for i, frame in enumerate(iter_scenario(args.scenario, args.count, args.seed)):
            f.write(f"# frame {i}: {frame.description}\n")
            f.write(frame.payload.hex() + "\n")

    print(f"wrote {args.count} frames (scenario={args.scenario}, seed={args.seed}) to {args.out}")


if __name__ == "__main__":
    main()
