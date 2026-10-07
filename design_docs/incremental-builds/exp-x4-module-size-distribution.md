# X4: Module-size distribution: lowering cost per module-aligned unit

**Status:** run on 2026-10-06 in a bootstrapped copy of the tree (`/tmp/inc-exp/repo`). Raw data is
in `/tmp/inc-exp/results/x45/`, and the instrumentation patch in
`experiments/x45-ecosplit-module-policy.patch`.

**Question (07 §2):** if units are aligned to Elm source modules, how much single-threaded
lowering time does each unit cost? Which modules are too slow to be one unit if we want an edit's
back-end latency to be about 1 s?

## Method

- **Input:** the compiler's own optimized MLIR, Stage 7a
  `eco-compiler-boot.mlir` (13.4 MB, 76,337 defined functions after the whole-program passes).
- **Lowering:** `eco-boot-native`, with an experiment-only partition policy added to EcoSplit.
  - **`ECO_SPLIT_POLICY=module`.** Each defined function goes to the unit of the Elm module it was
    specialized from, recovered from its symbol name (`<Module_Path>_<name>_$_<specId>`). A
    function with no recoverable module takes the unit of its first referrer in module order,
    following edges through globals (eval descriptors) as well. That covers lambdas
    (`<entry>_lambda_<uid>`), local tail functions, `$cap`/`$clo` clones, closure wrappers and
    accessors.
  - **`ECO_SPLIT_POLICY=module-req`.** As above, but a function from a *package* module (anything
    outside the compiler's own top-level directories) counts as unattributed. Package instances
    therefore follow their first requester. This approximates the "requester ownership" of 02 §2,
    with one copy per instance (see the limitations).
- **Per-unit measurements** (`ECO_SPLIT_PART_STATS`):
  - owned functions and ops, declarations and import copies;
  - LLVM instructions after translation;
  - translate wall time, back-end wall time and thread CPU time;
  - object size.
- **Single-threaded cost.** Workers were capped at 12 concurrent (`ECO_SPLIT_MAX_THREADS=12`) on
  the 12-core container, so a unit's thread CPU time approximates its single-threaded lowering
  latency.
- **Isolation.** All runs held the experiments' machine-wide heavy-job lock.

## Results

### Units under requester attribution (`module-req`, 272 units, 471 core-seconds in total)

**Distribution of per-unit cost:**
- median 0.63 s, p90 4.3 s, p99 22 s, max 27.5 s.

| Unit CPU (s) | Units | Share of total CPU |
|---|---:|---:|
| ≤ 0.25 | 82 | 1.5 % |
| 0.25-0.5 | 38 | 2.9 % |
| 0.5-1 | 46 | 6.8 % |
| 1-2 | 44 | 13.2 % |
| 2-5 | 39 | 25.2 % |
| 5-10 | 14 | 20.3 % |
| > 10 | 9 | 30.0 % |

**Splitting needed to reach a per-unit latency target**, assuming oversize units split linearly:

| Target per unit | Units over the target | Total units after splitting |
|---|---:|---:|
| 1 s | 106 | ≈ 640 |
| 2 s | 62 | ≈ 425 |
| 5 s | 23 | ≈ 310 |

**The ten most expensive units:**

| Unit | CPU (s) | Functions | LLVM insts | Source lines |
|---|---:|---:|---:|---:|
| Compiler.Parse.Primitives | 27.5 | 4,111 | 180,630 | 780 |
| Compiler.Parse.Shader | 22.1 | 5,213 | 125,108 | 317 |
| Compiler.Reporting.Error.Syntax | 22.0 | 1,663 | 157,954 | 12,701 |
| Utils.Main | 15.2 | 2,403 | 81,362 | 1,749 |
| Compiler.MonoSolver.Monomorphize | 12.2 | 1,252 | 65,205 | 5,156 |
| Compiler.MonoSolver.Translate | 11.0 | 1,001 | 52,069 | 7,633 |
| Data.Map | 10.8 | 1,195 | 52,780 | 260 |
| Compiler.AST.Source | 10.5 | 1,820 | 55,470 | 2,120 |
| Compiler.Generate.MLIR.BytesFusion.Emit | 10.3 | 116 | 43,576 | 2,711 |
| Builder.Elm.Details | 9.1 | 2,124 | 53,791 | 2,451 |

### Units under definition attribution (`module`, 327 units)

- median 0.33 s, p90 3.3 s, max 48 s.
- The two largest units are the package modules `List` (48.1 s, 6,495 functions) and `Dict`
  (45.7 s, 4,841 functions), plus `Combine` (11.5 s). These are where every instance of those
  packages' generic functions lands.
- Package-module units total 123 of 441 core-seconds (28 %).

### What predicts cost

| Predictor | Correlation with unit CPU |
|---|---:|
| LLVM instruction count | 0.94 (`module`), 0.98 (`module-req`) |
| Source lines (project modules) | 0.69 (`module`), 0.59 (`module-req`) |

## What this means

1. **Source-module size is a poor proxy for back-end cost.** The cost is in the *specializations
   a module owns*, not its source lines.
   - `Compiler.Parse.Primitives` (780 lines) and `Compiler.Parse.Shader` (317 lines) are among the
     most expensive units, because they own thousands of instances of parser-combinator generics.
   - `Reporting.Error.Syntax` is expensive simply because it is huge (12.7k lines).
   - Any splitting rule must use an instruction-count or op-count estimate, as plan 06 already
     found for LPT.
2. **Under definition attribution, package modules are the hot spots.** `List` and `Dict` alone
   would make any edit that changes a `List`/`Dict` instance cost ~45 s of single-threaded
   lowering. Two things are needed: requester ownership (02 §2) or a sharded package pool
   (variant C), *and* splitting.
3. **Requester attribution moves the hot spots onto the first requester.**
   - This run approximates requester ownership with **one copy per instance, owned by the first
     referrer.** The package-instance load therefore lands on whichever module references a
     package first: `Parse.Shader` owns 5,213 functions from 317 lines of source.
   - True variant A would duplicate such instances into each requester. Variant C would pool
     them. X2 measures that trade-off.
4. **Latency target vs unit count.**
   - A ≤ 1 s back-end latency for a one-unit edit needs about 640 units.
   - A ≤ 2 s target needs about 425.
   - 89 % of the CPU sits in the 106 units above 1 s, so splitting is concentrated in about 100
     modules. The ~120 units under 0.5 s could merge into a few buckets (06 §3).

## Limitations

- Module attribution is recovered from symbol names, with a referrer fallback. It is not the
  front end's own ownership.
- "Requester" here means *first* referrer, so instances are not duplicated. A true per-requester
  copy would raise total CPU (see X2).
- Thread CPU under 12-way concurrency includes some memory-bandwidth contention. The total
  (471 s) is close to the LPT-12 sum (450 s), so the distortion is small.
- One input (the compiler itself) and one machine (12 cores).
