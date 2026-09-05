"""sim/gen_soak_vectors.py

Generates the flat byte-stream vector tb/tb_parser_soak.v loads via
$readmemh, for the S2 milestone's "1M-message parse, zero loss" gate
(master spec S15 S2 row) -- distinct from the four directed tests
(T01/T02/T05/T06) in tb_frame_classifier.v/tb_md_parser.v.

Reuses feed_gen.py's existing "normal" scenario (S1, unmodified) rather
than inventing a second stimulus generator: each "normal" frame is exactly
one well-formed 16-byte QUOTE message (sim/feed_gen.py's _normal()), so the
output here is simply every generated frame's 16 bytes concatenated, one
hex byte per line -- $readmemh's expected format. No frame-boundary
metadata file is needed alongside it: tb_parser_soak.v already knows every
frame in this set is exactly 16 bytes (rx_len=16 for all of them), so it
drives frame_start/rx_len itself without reading it back out of this file.

Header line uses // (not #): $readmemh skips // comments but not #.
Output is committed nowhere -- tb/stimulus/*.mem is gitignored (it is ~16
MB at 1,000,000 messages and fully regenerable) -- only this generator is
checked in.

CLI usage:
  python sim/gen_soak_vectors.py --count 1000000 --seed 7 --out tb/stimulus/s2_soak.mem
"""

from __future__ import annotations

import argparse

from feed_gen import iter_scenario


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--count", type=int, default=1_000_000, help="number of messages (== frames, 1:1 for 'normal')")
    ap.add_argument("--seed", type=int, required=True, help="recorded in a header comment for reproducibility")
    ap.add_argument("--out", required=True, help="output .mem path ($readmemh-compatible)")
    args = ap.parse_args()

    with open(args.out, "w") as f:
        f.write(f"// scenario=normal count={args.count} seed={args.seed}\n")
        n_bytes = 0
        for frame in iter_scenario("normal", args.count, args.seed):
            assert len(frame.payload) == 16, "gen_soak_vectors assumes one 16-byte message per frame"
            for b in frame.payload:
                f.write(f"{b:02x}\n")
            n_bytes += len(frame.payload)

    print(f"wrote {args.count} messages ({n_bytes} bytes) to {args.out}")


if __name__ == "__main__":
    main()
