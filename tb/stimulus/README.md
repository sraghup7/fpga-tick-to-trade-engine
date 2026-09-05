# tb/stimulus/

Generated test vectors from `sim/feed_gen.py` (seeded, reproducible — a failure must be
re-runnable from its seed alone, per master spec §11.2). This directory holds generated
output, not hand-authored files — everything in it (currently `s2_soak.mem`, from
`sim/gen_soak_vectors.py`, S2's 1M-message soak stimulus) is gitignored (`tb/stimulus/*.mem`)
and safe to delete/regenerate.
