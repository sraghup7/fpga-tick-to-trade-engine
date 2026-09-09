#!/usr/bin/env python3
"""Load model/model_config.json's trained normalization offsets/shifts and
hysteresis thresholds into the FPGA's runtime-configurable CSR registers
over UDP (docs/contracts/csr_block.md S2.2 frame format; register addresses
from fpga_tick_to_trade_master_spec.md S9 / rtl/csr_block.v).

Weights/bias are NOT covered here -- they are elaboration-time-baked via
$readmemh (rtl/ml_classifier_wrap.v), not CSR-writable (FR-32); swapping
them means re-synthesizing with new model/weights.mem/bias.mem, not a CSR
write. Only cfg_offset_0..7, cfg_shift_0..7, cfg_ml_th_high, cfg_ml_th_low
are runtime-writable and are what this script loads.

Usage:
    python scripts/load_ml_model.py --host 192.168.1.50 --port 60000
    python scripts/load_ml_model.py --dry-run   # print frames, send nothing
"""
from __future__ import annotations

import argparse
import json
import socket
import struct
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = REPO_ROOT / "model" / "model_config.json"

CSR_WRITE = 0x20

# Register addresses, fpga_tick_to_trade_master_spec.md S9 / rtl/csr_block.v.
ADDR_ML_TH_HIGH = 0x0048
ADDR_ML_TH_LOW = 0x004C
ADDR_OFFSET = [0x0060, 0x0064, 0x0068, 0x006C, 0x0070, 0x0074, 0x0078, 0x007C]
ADDR_SHIFT = [0x0080, 0x0084, 0x0088, 0x008C, 0x0090, 0x0094, 0x0098, 0x009C]


def build_csr_write_frame(addr: int, data: int) -> bytes:
    """16-byte big-endian CSR write envelope (docs/contracts/csr_block.md S2.2):
    byte0=msg_type(0x20), byte1=reserved(0), bytes2-3=addr, bytes4-7=data,
    bytes8-15=reserved(0). Matches the exact frame layout already used by
    sim/gen_top_soak_vectors.py's own `_csr_frame_pack` helper
    (`struct.pack(">BBHIQ", mt, 0, addr, data, 0)`) -- same 16 bytes, just
    spelled with an explicit 8x pad instead of a zero Q field.
    """
    return struct.pack(">BBHI8x", CSR_WRITE, 0, addr & 0xFFFF, data & 0xFFFFFFFF)


def build_frames(cfg: dict) -> list[tuple[str, bytes]]:
    frames = []
    frames.append(("ML_TH_HIGH", build_csr_write_frame(ADDR_ML_TH_HIGH, cfg["t_high"])))
    frames.append(("ML_TH_LOW", build_csr_write_frame(ADDR_ML_TH_LOW, cfg["t_low"])))
    for i, offset in enumerate(cfg["offsets"]):
        frames.append((f"ML_OFFSET_{i}", build_csr_write_frame(ADDR_OFFSET[i], offset)))
    for i, shift in enumerate(cfg["shifts"]):
        frames.append((f"ML_SHIFT_{i}", build_csr_write_frame(ADDR_SHIFT[i], shift)))
    return frames


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(DEFAULT_CONFIG), help="path to model_config.json")
    ap.add_argument("--host", default="127.0.0.1", help="board IP (or sim host)")
    ap.add_argument(
        "--port", type=int, default=60000,
        help="cfg_udp_port (register 0x40 default -- matches rtl/csr_block.v:268's reset value)",
    )
    ap.add_argument("--dry-run", action="store_true", help="print frames, send nothing")
    args = ap.parse_args()

    try:
        with open(args.config) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise SystemExit(f"failed to load {args.config}: {e}")

    if len(cfg["offsets"]) != 8 or len(cfg["shifts"]) != 8:
        raise SystemExit(f"expected 8 offsets/shifts, got {len(cfg['offsets'])}/{len(cfg['shifts'])}")

    # cfg_ml_th_high/cfg_ml_th_low are signed 32-bit registers (rtl/csr_block.v);
    # cfg_offset_i/cfg_shift_i are 32-bit registers that legitimately carry
    # negative offsets (e.g. F1_mid_delta's mean can be negative) -- both are
    # handled correctly by build_csr_write_frame's `& 0xFFFFFFFF` mask for any
    # IN-RANGE value, but a genuinely out-of-range value (corrupted config,
    # bad retrain) would silently wrap instead of erroring. Catch that here.
    for name, val in [("t_high", cfg["t_high"]), ("t_low", cfg["t_low"])]:
        if not (-(2**31) <= val <= 2**31 - 1):
            raise SystemExit(f"{name}={val} does not fit in a signed 32-bit register")
    for i, val in enumerate(cfg["offsets"]):
        if not (-(2**31) <= val <= 2**32 - 1):
            raise SystemExit(f"offsets[{i}]={val} does not fit in a 32-bit register")
    for i, val in enumerate(cfg["shifts"]):
        if not (0 <= val <= 2**32 - 1):
            raise SystemExit(f"shifts[{i}]={val} does not fit in a 32-bit register (shift must be non-negative)")

    frames = build_frames(cfg)

    if args.dry_run:
        for name, frame in frames:
            print(f"{name}: {frame.hex()}")
        return

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for name, frame in frames:
        sock.sendto(frame, (args.host, args.port))
        print(f"sent {name} -> {args.host}:{args.port}")
    sock.close()
    print(f"loaded {len(frames)} CSR registers from {args.config}")


if __name__ == "__main__":
    main()
