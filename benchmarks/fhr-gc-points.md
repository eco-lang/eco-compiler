# Optional forced major GC points: what they change and what they cost (2026-10-01)

> **Outcome:** these seven optional points were **removed from the compiler** on 2026-10-01 at the user's decision, because of the results below. `pre-link` (ELF output) stays on by default. See `plans/frontend-heap-release.md` §11.7.

**Setup.**
- **Workload:** the gc-opt-loop.md §2 self-compile, cold `eco-stuff` and the registry touched before every run, `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1`, `/usr/bin/time -v`.
- **Binary:** `eco-optFHR`, the tree with `plans/frontend-heap-release.md` Parts A-E. Each run sets `ECO_GC_POINTS=<config>` and `ECO_GC_REPORT=1`.
- **Runs:** one per configuration, strictly serial, no A/B arms.
- **Output:** `--output=….mlir`, so the `pre-link` GC (ELF output only) does not run here. Only the optional points fire.
- **Validity:** every run exited 0, had no `[gc-stats] SIG`, and produced output byte-identical to `ecoFHR.mlir` (13,264,494 B).
- **Files:** script `benchmarks/fhr-gc-points-runs.sh`; raw `.time`/`.stdout`/`.stderr` in `benchmarks/fhr-gcpoints/`.

**Context row (recorded, not re-run).** The FHR entry in gc-opt-loop.md, same binary with no points, median of three: wall 107.04 s (spread 106.28-107.71), GC 7.86 s, minors 2558, majors 11, promoted 20,525 MiB, max RSS 9,840,052 kB, old-gen in-use peak 8,820 MB.

## Results

| config | wall (s) | GC time (s) | minors | majors | promoted MiB | max RSS (kB) | old-gen in-use peak (MB) | user CPU (s) | forced GC time (ms) |
|---|---|---|---|---|---|---|---|---|---|
| *(context: no points, FHR median)* | *107.04* | *7.86* | *2558* | *11* | *20525* | *9,840,052* | *8,820* | *~183* | *0* |
| **all 7 points** | **116.74** | **15.34** | 2558 | **20** | 20525 | 9,842,320 | 8,821 | 193.97 | **7,930** |
| post-build | 109.25 | 9.34 | 2558 | 12 | 20525 | 9,845,128 | 8,822 | 184.16 | 1,744 |
| post-merge | 111.16 | 9.48 | 2558 | 12 | 20525 | 9,845,364 | 8,823 | 186.10 | 1,808 |
| post-assign | 109.62 | 10.23 | 2558 | 12 | 20525 | 9,834,428 | 8,814 | 184.86 | 2,690 |
| post-mono | 107.84 | 8.25 | 2558 | 13 | 20525 | 9,838,496 | 8,817 | 183.41 | 541 |
| post-inline | 108.36 | 8.29 | 2558 | 13 | 20525 | 9,838,832 | 8,816 | 184.83 | 544 |
| post-globalopt | 108.45 | 8.51 | 2558 | 13 | 20525 | 9,838,524 | 8,817 | 184.34 | 730 |
| post-codegen-nodes | 108.73 | 8.24 | 2558 | 12 | 20525 | 9,846,928 | 8,824 | 184.31 | 628 |

### The forced collection at each point, as single-point runs

| point | live at point (MB) | RSS before → after (MB) | pause (ms) | of which major / sweep / discard |
|---|---|---|---|---|
| post-build | 1,500 | 7,357 → 3,722 | 1,744 | 1,563 / 73 / 106 |
| post-merge | 1,515 | 7,363 → 3,722 | 1,808 | 1,629 / 73 / 105 |
| post-assign | 2,380 | 7,351 → 4,900 | 2,690 | 2,517 / 109 / 62 |
| post-mono | 169 | 7,354 → 1,853 | 541 | 363 / 33 / 144 |
| post-inline | 158 | 7,353 → 1,899 | 544 | 355 / 44 / 145 |
| post-globalopt | 153 | 7,495 → 1,970 | 730 | 525 / 55 / 150 |
| post-codegen-nodes | 206 | 7,659 → 1,950 | 628 | 418 / 56 / 153 |

## What the forced GCs change

- **Nothing in the program's allocation.** Minors (2558) and promoted MiB (20,525) are identical in every run, and so is the output.
- **Majors.** Each point adds its own major. A run with one point has 12-13 majors against 11 without.
  - The 13s (post-mono, post-inline, post-globalopt) are one forced major plus one extra automatic major. A forced release lowers the heap, so the live-budget trigger fires once more later.
  - `all` has 20: 7 forced points, one of which (post-globalopt) also had to finish a concurrent cycle (`majors_run=2`), plus extra automatic majors.
- **Peak memory: no change.** Max RSS stays at 9.83-9.85 GB and the old-gen in-use peak at 8.81-8.82 GB in every configuration, with or without points. The peak happens in the build/type-check phase, about 53-57 s in, before the first point (post-build).
- **Memory between the points does drop, and a lot.** Each point cuts RSS from about 7.4 GB to 1.9-4.9 GB, depending on the live set at that moment (§ table above). The later points (post-mono onwards) leave about 1.9 GB. But the process has already reached its peak by then and never comes back to it, so the overall maximum doesn't move.

## What they cost

- **Wall.** Measured against the no-point context median of 107.04 s; a single run has roughly ±1 s of noise.
  - The four late points (post-mono, post-inline, post-globalopt, post-codegen-nodes) add **+0.8 to +1.7 s** each. Each forced GC is 0.5-0.7 s, and the rest is re-faulting the discarded pages and the extra automatic major.
  - The three early points cost more: post-build **+2.2 s**, post-assign **+2.6 s**, post-merge **+4.1 s** (the post-merge figure may include noise). Their forced GCs are 1.7-2.7 s, because 1.5-2.4 GB is live when they run.
  - **All seven together: +9.7 s (+9 %).** GC time rises by +7.5 s, which is almost exactly the 7.9 s spent in the forced GCs themselves.
- **CPU.** User time rises by about 1-3 s per single point (the parallel mark), and by about 11 s for all seven.

## Conclusion

On this workload the optional points buy **no reduction in peak memory**, at a wall cost of about +1 to +4 s each and about +10 s for all of them. They only lower the resident memory *between* stages, after the peak has passed. They would only help a workload whose peak comes later in the pipeline, for example a back end or later phase that grows after one of the points.

The default stays: **all optional points off**, with the `pre-link` release on for ELF output. That one returned 8.0 GB → 0.9 GB before the back end in the Stage 9b runs, and lowered that peak from 14.6 to 9.7 GB.
