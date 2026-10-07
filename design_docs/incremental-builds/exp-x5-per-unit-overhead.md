# X5: Per-unit overhead at module granularity

**Status:** run on 2026-10-06 in a bootstrapped copy of the tree (`/tmp/inc-exp/repo`). Raw data is
in `/tmp/inc-exp/results/x45/` (`*.tsv` per-partition stats, `*.time`, `runtime/`). Scripts and the
patch are in `experiments/` (`x45-run-lowering.sh`, `x45-ecosplit-module-policy.patch`,
`time-compile.sh`).

**Question (07 §2):** module-aligned units mean hundreds of partitions instead of 12-36.

- What fixed cost does each extra unit add to a clean build?
- What does finer, module-aligned partitioning cost in generated-code quality?

The fear comes from plan 06 C4, which measured about 0.93 core-seconds of extra Σ-translate per
extra LPT partition, driven by ~5.2k declarations per partition.

## Method

Same input and instrumentation as X4. The compiler's own Stage 7a MLIR was lowered with
`eco-boot-native` under five partitionings, with workers capped at 12 concurrent on the 12-core
container:

| Run | Partitioning | Units |
|---|---|---:|
| `lpt12` | LPT by op count (today's default: 12 cores here) | 12 |
| `lpt24` | LPT, `--split-codegen=24` | 24 |
| `lpt36` | LPT, `--split-codegen=36` | 36 |
| `module` | by definition module (X4) | 327 |
| `modreq` | by module, package instances following their first requester (X4) | 272 |

For each run we recorded:
- per-unit thread CPU, declarations, `$cap` import copies, LLVM instructions after translation, and
  object bytes;
- total wall time and user CPU;
- binary sections.

**Code-quality check.** Each produced compiler binary was then timed compiling the pristine compiler
source to MLIR: cold cache, 3 runs per binary, interleaved round-robin, each holding the machine-wide
lock.

## Results

### Lowering cost

| Run | Units | Σ worker CPU (s) | Wall (s) | Biggest unit (s) | Declarations | `$cap` imports | LLVM insts after translate | Σ translate (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| lpt12 | 12 | 450.3 | 50.4 | 44.7 | 110,672 | 1,881 avg/partition | 4.15 M | 18.7 |
| lpt24 | 24 | 468.7 | 51.3 | 25.7 | 125,057 | 1,019 | 4.25 M | 19.7 |
| lpt36 | 36 | 462.3 | 50.3 | 16.7 | 131,698 | 696 | 4.27 M | 19.3 |
| module | 327 | 440.9 | 62.6 | 48.1 | 25,598 | 3 avg (max 127) | 2.96 M | 13.8 |
| modreq | 272 | 471.1 | **46.9** | 27.5 | 18,375 | 1 avg (max 45) | 2.94 M | 12.7 |

Process user time was 476.7 s (lpt12), 496.9, 490.0, 468.3 and 498.3 s respectively.

### Binary

| Run | `.text` | `.llvm_stackmaps` | Binary |
|---|---:|---:|---:|
| lpt12 (byte-identical to the Stage 7b `eco-compiler-boot`) | 31.26 MB | 29.47 MB | 91.96 MB |
| module | 31.72 MB (+1.5 %) | 29.46 MB | 92.44 MB |
| modreq | 31.94 MB (+2.2 %) | 29.45 MB | 92.64 MB |

### Generated-code quality (wall time to compile the compiler to MLIR, N = 3)

| Binary | Runs (s) | Median | vs lpt12 |
|---|---|---:|---:|
| lpt12 | 66.32 / 66.42 / 66.75 | 66.42 | — |
| module | 65.49 / 66.62 / 66.79 | 66.62 | +0.3 % (noise) |
| modreq | 66.22 / 66.41 / 67.00 | 66.41 | −0.0 % |

All three binaries produced byte-identical MLIR, identical to Stage 7a's output.

## What this means

1. **Per-unit overhead at module granularity is negligible.**
   - Going from 12 LPT partitions to 272-327 module units changed total worker CPU by −2 % to
     +5 %.
   - The C4 figure (0.93 core-s per extra partition) does **not** carry over. That overhead came
     from declarations and `$cap` import copies, which grow with the number of *random*
     partitions.
   - Module-aligned units reference far fewer foreign symbols: 18-26k declarations in total
     instead of 110-132k. They have almost no import copies, because most `$cap` callees live in
     the same module. They even translate faster in total (12.7 s against 18.7 s).
   - **The clean-build penalty assumed in 06 §4 (~12-16 s) is not real.** A clean build with
     ~300 module units costs about the same CPU as today's.
2. **Losing cross-partition `$cap` inlining costs nothing measurable at runtime.**
   - Module units have almost no import copies.
   - The produced compiler runs at the same speed (±0.3 %, within noise).
   - Code is 1.5-2.2 % larger (`.text`), which is consistent with fewer inlined-and-deleted `$cap`
     bodies.
3. **Wall time depends on the biggest unit, not the count.**
   - `modreq` finishes *faster* than LPT-12 (46.9 s against 50.4 s), because its largest unit is
     27.5 s against LPT's 12 × ~40 s.
   - `module` is slower (62.6 s), because `List` and `Dict` are 48 s and 46 s single units.
   - So module alignment is compatible with clean-build throughput, *provided* the hot units are
     split (X4).
4. **For 06:**
   - The granularity tension in 06 §4 ("stable small units vs per-unit overhead") largely
     dissolves.
   - Module-aligned units with large modules split, roughly 400-650 units for 1-2 s per-unit
     latency (X4), look affordable on both CPU and code quality.
   - The remaining cost is the extra objects at link time, which was not measured here.

## Limitations

- Units come from symbol-name attribution with a referrer fallback, not front-end ownership, and
  there is no per-requester duplication (see X2 for that cost).
- Splitting large modules was not tried. More units would add some declarations, though still far
  fewer than random partitions.
- Link time with 300 objects was not isolated. Lowering wall time includes the link, and `modreq`
  was still the fastest overall.
- One machine (12 cores) and one program.
