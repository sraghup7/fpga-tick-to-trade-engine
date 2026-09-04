"""sim/order_rx.py

Host-side order-stream receiver / latency log parser (master spec S3.1's
`order_rx.py`, S8's stated milestone gate: "Order frames decoded by
order_rx.py"). Decodes the 16-byte order-output wire format (S4.5) using
`golden_model.OrderRecord` as the single source of truth for that format --
this module never re-implements the struct layout, so it can't drift from
what `sim/golden_model.py` and `rtl/order_builder.v`'s own contract agree on.

Two ingestion modes, same as `feed_gen.py`'s offline-first design (its own
docstring: "a live-UDP-traffic mode can be layered on top... later"):

  --in <hexfile>   offline capture, one hex-encoded 16-byte order record per
                    line (`#`-prefixed comment lines ignored) -- the same
                    line format `feed_gen.py` writes for market-data frames,
                    reused here for order records. Usable today, without
                    hardware: decode a capture written by any source (a
                    testbench $writememh dump, a Wireshark hex export, or
                    `--selftest`'s own round-trip file).
  --udp <port>      live UDP listener -- each datagram's payload is one
                    16-byte order record, per S4.5 ("one order per frame in
                    v1"). Exists for S11 hardware bring-up; nothing sends
                    live UDP order traffic yet (no hardware, no `eth_mac_tx`
                    wired up) so this path is unexercised until then --
                    exactly the position `feed_gen.py`'s UDP send side is in
                    today.

CLI usage:
  python sim/order_rx.py --in captures/orders.hex
  python sim/order_rx.py --udp 5006
  python sim/order_rx.py --selftest
"""

from __future__ import annotations

import argparse
import socket
import sys
from dataclasses import dataclass, field
from typing import Iterator, Optional

from golden_model import (
    GATE_NAME,
    ORDER_MSG_NEW,
    ORDER_MSG_REJECT,
    ORDER_MSG_STATS,
    OrderRecord,
    SIDE_ASK,
    SIDE_BID,
)

SIDE_NAME = {SIDE_BID: "buy", SIDE_ASK: "sell"}
MSG_TYPE_NAME = {
    ORDER_MSG_NEW: "new_order",
    ORDER_MSG_REJECT: "risk_reject",
    ORDER_MSG_STATS: "stats",
}


def format_record(rec: OrderRecord) -> str:
    """One human-readable line per decoded order record."""
    kind = MSG_TYPE_NAME.get(rec.msg_type, f"unknown(0x{rec.msg_type:02x})")
    side = SIDE_NAME.get(rec.side, f"0x{rec.side:02x}")
    if rec.reject_reason == 0:
        reason = "accepted"
    else:
        reason = GATE_NAME.get(rec.reject_reason, f"gate_0x{rec.reject_reason:02x}")
    return (
        f"{kind:11s} sym={rec.symbol_id:3d} {side:4s} "
        f"price={rec.price:>8d} qty={rec.quantity:>6d} "
        f"trigger_seq={rec.trigger_seq:5d} latency_cyc={rec.latency_cyc:5d} "
        f"reject_reason={reason}"
    )


@dataclass
class Stats:
    """Running aggregate over every decoded record -- printed as a summary
    at the end of a capture/session, not per-record."""

    total: int = 0
    by_msg_type: dict = field(default_factory=dict)
    by_reject_reason: dict = field(default_factory=dict)
    by_side: dict = field(default_factory=dict)
    accepted_latencies: list = field(default_factory=list)

    def observe(self, rec: OrderRecord) -> None:
        self.total += 1
        kind = MSG_TYPE_NAME.get(rec.msg_type, f"unknown(0x{rec.msg_type:02x})")
        self.by_msg_type[kind] = self.by_msg_type.get(kind, 0) + 1
        side = SIDE_NAME.get(rec.side, f"0x{rec.side:02x}")
        self.by_side[side] = self.by_side.get(side, 0) + 1
        reason = "accepted" if rec.reject_reason == 0 else GATE_NAME.get(
            rec.reject_reason, f"gate_0x{rec.reject_reason:02x}"
        )
        self.by_reject_reason[reason] = self.by_reject_reason.get(reason, 0) + 1
        # NFR-1/FR-54: latency_cyc is only a meaningful tick-to-trade
        # measurement for an actually-accepted order (msg_type=new_order);
        # a 0x11 reject-diagnostic frame's latency_cyc reflects the same
        # timestamp point but isn't the headline claim these stats exist
        # to support (S12.1's single-occupancy histogram), so it's kept
        # out of this particular aggregate to avoid conflating the two.
        if rec.msg_type == ORDER_MSG_NEW:
            self.accepted_latencies.append(rec.latency_cyc)

    def summary(self) -> str:
        lines = [f"total records: {self.total}"]
        if self.by_msg_type:
            lines.append("  by msg_type:      " + ", ".join(
                f"{k}={v}" for k, v in sorted(self.by_msg_type.items())
            ))
        if self.by_side:
            lines.append("  by side:           " + ", ".join(
                f"{k}={v}" for k, v in sorted(self.by_side.items())
            ))
        if self.by_reject_reason:
            lines.append("  by reject_reason:  " + ", ".join(
                f"{k}={v}" for k, v in sorted(self.by_reject_reason.items())
            ))
        if self.accepted_latencies:
            lat = self.accepted_latencies
            lines.append(
                f"  latency_cyc (accepted orders only): "
                f"min={min(lat)} max={max(lat)} mean={sum(lat) / len(lat):.1f} "
                f"n={len(lat)}"
                + ("  <-- single value: NFR-2's claimed property" if min(lat) == max(lat) else
                   "  <-- SPREAD: NFR-2 requires exactly one occupied bucket, this is a functional bug once real RTL/hardware feeds this")
            )
        return "\n".join(lines)


def iter_hex_file(path: str) -> Iterator[bytes]:
    """Yield each decoded 16-byte order record from an offline capture file
    in `feed_gen.py`'s own line format: `#`-prefixed comments ignored,
    every other non-blank line is one hex-encoded record."""
    with open(path, "r") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                raw = bytes.fromhex(line)
            except ValueError as e:
                raise ValueError(f"{path}:{line_no}: not valid hex ({e})") from e
            if len(raw) != 16:
                raise ValueError(
                    f"{path}:{line_no}: order record must be exactly 16 bytes, got {len(raw)}"
                )
            yield raw


def iter_udp(port: int, host: str = "0.0.0.0", count: Optional[int] = None) -> Iterator[bytes]:
    """Yield each 16-byte order record received as a UDP datagram's payload.
    Blocks waiting for datagrams; runs until `count` records are received
    (or forever if `count` is None -- stop with Ctrl+C). S4.5: one order
    per frame in v1, so one datagram is exactly one record; a datagram of
    any other length is reported and skipped rather than raising, since a
    live socket seeing unexpected traffic shouldn't kill the whole capture."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((host, port))
    print(f"listening for order frames on UDP {host}:{port} ... (Ctrl+C to stop)", file=sys.stderr)
    received = 0
    try:
        while count is None or received < count:
            raw, addr = sock.recvfrom(65535)
            if len(raw) != 16:
                print(
                    f"WARNING: {addr[0]}:{addr[1]} sent {len(raw)}-byte datagram, "
                    f"expected exactly 16 (S4.5) -- skipped",
                    file=sys.stderr,
                )
                continue
            yield raw
            received += 1
    finally:
        sock.close()


def run(records: Iterator[bytes], quiet: bool = False) -> Stats:
    stats = Stats()
    for raw in records:
        rec = OrderRecord.decode(raw)
        stats.observe(rec)
        if not quiet:
            print(format_record(rec))
    return stats


def selftest() -> None:
    """Round-trip every reject-reason value (accepted, and each of the nine
    gate IDs) plus both sides through encode -> hex line -> decode, proving
    this module's decoding agrees with golden_model.OrderRecord's own
    encoding without needing hardware or a live capture. This is this
    module's hand-case gate, same spirit as
    sim/test_golden_model_handcase.py and sim/test_feature_golden_handcase.py."""
    import tempfile
    import os

    cases = []
    for reason in [0, *GATE_NAME.keys()]:
        for side in (SIDE_BID, SIDE_ASK):
            cases.append(
                OrderRecord(
                    msg_type=ORDER_MSG_NEW if reason == 0 else ORDER_MSG_REJECT,
                    symbol_id=(reason * 2 + side) % 256,
                    side=side,
                    reject_reason=reason,
                    price=10_000 + reason,
                    quantity=100,
                    trigger_seq=1000 + reason,
                    latency_cyc=11,
                )
            )

    fd, path = tempfile.mkstemp(suffix=".hex")
    os.close(fd)
    try:
        with open(path, "w") as f:
            f.write("# selftest: encode -> hex -> decode round trip\n")
            for rec in cases:
                f.write(rec.encode().hex() + "\n")

        decoded = [OrderRecord.decode(raw) for raw in iter_hex_file(path)]
        if decoded != cases:
            for i, (want, got) in enumerate(zip(cases, decoded)):
                if want != got:
                    print(f"FAIL: record {i}: encoded {want!r}, decoded back {got!r}")
            raise SystemExit(1)

        stats = Stats()
        for rec in decoded:
            stats.observe(rec)
        expected_total = len(cases)
        if stats.total != expected_total:
            print(f"FAIL: stats.total={stats.total}, expected {expected_total}")
            raise SystemExit(1)
        expected_accepted = sum(1 for c in cases if c.reject_reason == 0)
        if stats.by_reject_reason.get("accepted", 0) != expected_accepted:
            print(
                f"FAIL: accepted count={stats.by_reject_reason.get('accepted', 0)}, "
                f"expected {expected_accepted}"
            )
            raise SystemExit(1)
        for reason_id, name in GATE_NAME.items():
            if stats.by_reject_reason.get(name, 0) != 2:  # 2 sides per reason
                print(f"FAIL: {name} count={stats.by_reject_reason.get(name, 0)}, expected 2")
                raise SystemExit(1)
    finally:
        os.remove(path)

    print(f"PASS: {len(cases)} order records (accepted + all 9 gate reasons, both sides) "
          f"round-trip through order_rx.py's hex-file decode path and stats aggregation exactly")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--in", dest="in_path", help="offline hex-capture file to decode")
    src.add_argument("--udp", type=int, metavar="PORT", help="live UDP port to listen on")
    src.add_argument("--selftest", action="store_true", help="run the offline hand-case check and exit")
    ap.add_argument("--count", type=int, default=None, help="--udp only: stop after this many records")
    ap.add_argument("--quiet", action="store_true", help="suppress per-record lines, print only the summary")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return

    if args.in_path:
        stats = run(iter_hex_file(args.in_path), quiet=args.quiet)
    elif args.udp:
        stats = run(iter_udp(args.udp, count=args.count), quiet=args.quiet)
    else:
        ap.error("one of --in, --udp, or --selftest is required")
        return

    print("---")
    print(stats.summary())


if __name__ == "__main__":
    main()
