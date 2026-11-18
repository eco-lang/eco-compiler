---
status: partial
updated: 2026-11-18
remaining: "Defaults on (K = 128, $cap copies kept, solo threshold, 32 B loops; §2e). Owed: eco-verify, full, run-aot-e2e with a forced split, stress with the defaults (bootstrap run 2026-11-18)"
---

# MLIR split backend 08: inlining of small callees that does not depend on the partition

**Master plan:** `plans/mlir-split-backend.md` (§4.1 ownership, §4.3 linkage).
**Parents:** `plans/mlir-split-backend-05-ecosplit.md` (EcoSplit), `plans/mlir-split-backend-06-partition-boundaries.md`
(item D, call-graph ownership, measured FLAT and not built).

`EB` = `runtime/src/codegen/EcoBackend.cpp`. `ES` = `runtime/src/codegen/EcoSplit.cpp`.

## 0. The problem

EcoSplit gives every defined function to one partition by LPT on MLIR op counts (`ES`
`buildPartitions`), with no regard for the call graph. LLVM can only inline a callee whose body is
in the caller's module. So whether a small helper is inlined into its hot caller depends on
whether LPT happened to put them in the same partition, and any change that moves function sizes
anywhere in the program can flip it.

**Observed (2026-11-18, the `examples/benchmarks` program, LLVM 24, eco-native):** the sha256
workload went 36 → 43 ms (+17-19 %, reproduced on a rebuild) when an unrelated PR (Bytes encoder
fusion, kernel callback fast paths) changed other functions' sizes. The SHA-256 round loop
(`_tail_round_…$cap`) is a different function in the two builds:

| per round | before | after |
|---|---|---|
| `call Sha256_rotr` (18-byte rotate helper) | 0 (inlined: 14 shift/rotate ops) | **6** |
| `call Sha256_State` (record constructor) | 0 (inlined) | **1** |
| owner of `Sha256_rotr` | the round function's partition | `Sha256_compress`'s partition |

~450 extra calls per 64-round block. Loop alignment (tested the same day: innermost loops 32/64 B,
functions 64 B) does not move sha256 at all, because the instructions differ, not only their
placement. spectral-norm (+16 %) is unexplained so far and is probably the same class (§2 S0).

**Goal:** a small callee that the whole-module path (`ECO_MLIR_SPLIT=0`) would inline is inlined
in the split path too, wherever LPT puts it. Success is measured as *split invariance* (§2 S1)
and as benchmark stability, not as a self-compile speedup: plan 06 S6 already showed the
self-compile is FLAT under call-graph ownership.

## 1. Constraints that shape the design

- **Two inlining points exist, with different rules:**
  - **Pre-RS4GC:** `runCapInlinePrepass` (`EB` ~3918) marks `$cap` bodies of ≤ 64 instructions
    (`ECO_CAP_INLINE_MAX_INSTS`) `alwaysinline` and runs AlwaysInliner. GC-bearing bodies are safe
    here only because slot-cast barriers are on. EcoSplit already supports it across partitions:
    the `Call`-bit closure into `$cap` bodies owned elsewhere is cloned as `available_externally`
    import copies (`ES` "Imports").
  - **Post-RS4GC:** the per-partition `-O2` cost-model inliner. It may inline only bodies with no
    statepoints, i.e. GC-free bodies stamped `gc-leaf-function` (CGEN_072). This is how
    `Sha256_rotr` (a spec, not a `$cap`) was inlined when it shared a partition.
- **No import copy may reach RS4GC.** Survivors of the prepass are turned back into declarations
  unconditionally (`EB` ~4227, CGEN_083: hard error otherwise), because a statepointed copy must
  never reach the post-RS4GC inliner.
- **The GC-free facts are whole-program and known in MLIR.** EcoGcFreePropagation (plan 02,
  CGEN_072 MLIR producer) stamps before the split, so every partition's declaration or copy can
  carry the owner's stamp. EcoSplit already clones declarations "with ALL attributes".
- **Function bodies of the split path must equal the translate-whole path's** (CGEN_083, G2). Any
  copy mechanism must preserve this: the copy is inlined or dropped, never emitted.
- Only programs with ≥ 4,000 defined functions split (`kMinFnsToSplit`). The benchmark program and
  the compiler self-compile do; small user programs do not, and are unaffected.

## 2. Spikes (do these first)

### S0. Classify the known regressions

For sha256 and spectral-norm, in the before/after binaries kept from the 2026-11-18 runs
(`/tmp/nopr/bench-build/bench`, `/tmp/align/bench-a16`; rebuild them if gone):
- list the calls present in one build's hot function and inlined in the other;
- for each callee: is it a `$cap` or a spec, its instruction count, whether it carries
  `gc-leaf-function`, its owner partition in each build (`ECO_MLIR_SPLIT_STATS`, or a census dump).

**Decides** which option covers the observed cases: a GC-free spec helper → option P (below); a
GC-bearing small spec → option Q; a single-caller helper → plan 06 D3 would have covered it too.

### S1. Split-invariance census (the metric for every step)

Lower the same MLIR twice: split (default) and `ECO_MLIR_SPLIT=0`. For every function present in
both, count direct calls to defined functions. A call in the split output whose callee the
whole-module output inlined is a **lost inline**. Report, for the benchmark program and the
self-compile:
- lost inlines, total and by callee family (`$cap`, spec, `$sat`, wrapper) and by callee size
  (≤ 16, ≤ 32, ≤ 64 instructions) and GC-free vs GC-bearing;
- the same weighted by a dynamic count where cheap (e.g. `perf record` call counts on the
  benchmark suite), since a lost inline in cold code costs nothing.

### S2. The upper bound: run the benchmark suite unsplit

Lower the benchmark program with `ECO_MLIR_SPLIT=0` (whole-module, every inline available) and
run the full suite once against the split build of the same MLIR. This is the most any option
here can buy at runtime, and the price in lowering wall time it would cost to get it the dumb
way. If unsplit is not measurably better than split on any workload, stop: the remaining
differences are layout (see the alignment experiment), not inlining.

## 2a. Spike results (2026-11-18)

**Correction (same day): `ECO_MLIR_SPLIT=0` is not whole-module.** It only turns EcoSplit off: the
backend translates one module, then `llvm::SplitModule` splits it into the same partition count
(by name hash) for parallel RS4GC/opt/emit. So the "whole" builds below are a *second, differently
placed split*, and S1/S2 compare two placements: that is why lost and gained counts are nearly
symmetric. A true single partition needs `ECO_SPLIT_MIN_FUNCS` above the function count (one
module, one thread: the benchmark program lowers in 15.7 s against 8.3 s split). §2b measures P
against that. S0's findings stand (the comparison builds kept the helpers with their callers).

Tooling: `ECO_MLIR_SPLIT_OWNERS=<file>` (new, `ES` `buildPartitions`) writes one line per defined
function: name, owner partition, op count, `leaf`/`gc` (the `gc-leaf-function` stamp), and the
partitions holding an import copy. The census compares `objdump -d` of the split and the
`ECO_MLIR_SPLIT=0` executables lowered from the same MLIR, counting direct `call`/tail `jmp` per
(caller, callee) for program functions. Scripts and data: `/tmp/s08/` (`census.py`, `fncalls.py`).
Both split lowerings were byte-identical to the shipped binaries (benchmark `bench-a16`, self-compile
`eco-compiler-boot`).

### S0: both known regressions are option P's class

| workload | hot loop | helper called, not inlined (PR build) | stamp, ops | owners before PR → after PR |
|---|---|---|---|---|
| sha256 | `_tail_round_…$cap` | `Sha256_rotr` ×6, `Sha256_State` ×1 | leaf, 25 / 35 | all in 1 → loop 1, helpers 0 |
| spectral-norm | `rowSum`'s `_tail_go_…$cap` | `SpectralNorm_a` ×1 | leaf, 18 | both in 0 → loop 1, `a` 0 |

The before-PR ownership comes from relowering the no-PR MLIR (regenerated with the kept no-PR `eco`)
with today's backend: its code is identical to the kept no-PR binary. The whole-module build inlines
all three helpers. spectral-norm is the same class as sha256 (§7 question answered). In both, the loop
is a `$cap` owned by partition 1 and copied into 0; the copy's body in 0 could inline the helper, but
the emitted body is partition 1's.

### S1: lost inlines

| program | fns / partitions | lost sites (pairs) | GC-free | cross-partition | gained sites |
|---|---|---|---|---|---|
| benchmarks | 5,599 / 2 | 459 (391) | 459 (100 %) | 445 (+5 into copied `$cap`s, 9 same) | 342 |
| self-compile | 78,311 / 24 | 892 (739) | 883 (99 %) | 885 (+7 into copied `$cap`s) | 899 |

- By callee family: spec 452 / 873, `$cap` 7 / 15, `$sat` 0 / 4.
- Cover of the lost GC-free spec sites by an op cap `K` (bench / self): ≤ 24 ops 65 % / 46 %,
  ≤ 32 ops 76 % / 59 %, **≤ 40 ops 88 % / 90 %**, ≤ 48 ops 95 % / 94 %, ≤ 64 ops 98 % / 98 %.
  S0's helpers are 18-35 ops.
- GC-bearing lost sites (option Q's class): 0 in the benchmarks, 9 in the self-compile (1 %).
- "Gained" sites are almost all same-partition: the whole-module inliner declining calls the
  smaller partition modules inline (caller-growth limits), not a split defect. P does not address
  them and should not try to.
- Dynamic weighting was not done: unprivileged `perf` is blocked (`perf_event_paranoid=3`); it
  works under `sudo -n perf`, found later. S2's per-workload timings, read together with the
  hot-function diffs, stand in for it.

### S2: unsplit is measurably better, so continue

The benchmark suite, split/unsplit/split/unsplit, same MLIR (74 workloads, all checks OK):
geomean **unsplit/split 0.982**. Lowering the benchmark program unsplit costs 8.98 s against 8.29 s
split; the self-compile costs 57.1 s against 19.9 s (RSS 5.46 against 7.24 GB). Workloads that moved
more than 5 % and more than twice their split-to-split noise:

| workload | unsplit/split | cause (hot functions compared) |
|---|---|---|
| spectral-norm | 0.859 | inlining (`SpectralNorm_a`, S0) |
| sha256 | 0.918 | inlining (`rotr`, `State`, S0) |
| levenshtein | 0.950 | `Levenshtein_distance` differs in what it inlines; small |
| fib, hot-lambda | 0.905, 0.912 | layout: hot functions identical |
| binary-trees, merkletrees | 1.070, 1.069 | layout, against unsplit: hot functions identical |

**Decision:** build P (step 2) with `K` starting at 40 ops. Q is not justified (no GC-bearing lost
sites in the benchmarks, 1 % in the self-compile). R is not needed: every lost site P misses is a
callee over `K`, not a single-caller placement problem.

## 2b. Step 2: P built and measured at K = 40 (2026-11-18)

Built behind `ECO_SPLIT_IMPORT_LEAF_MAX_OPS` (default 0 = off; only under parallel-opt `cgu`):
- `ES` `buildPartitions`: the import closure also follows direct calls into non-`$cap` functions
  stamped `gc-leaf-function` with at most K ops; their owners export them normally;
  `ECO_MLIR_SPLIT_STATS` reports `leafImports(avg/max)`.
- `EB`: `isLeafImportCopy` (available_externally + gc-leaf + not `$cap`) exempts these copies
  from the post-prepass drop, from the "no available_externally reaches RS4GC" error and from
  `checkStampedBodies`' linkage check (its leaf-calls check still applies); the (X) join reports
  them as declarations. The existing post-RS4GC scan (any stamped function containing a
  statepoint is fatal) is the plan's "copy stays statepoint-free" assertion, in every build type.
- CGEN_083 amended; `EcoSplit.h` documents leaf import copies.

Results:
- **Off is byte-identical** to the shipped binaries (benchmark program and self-compile).
  K = 40 is deterministic (two self-compile lowerings byte-identical).
- **S0 fixed:** at K = 40 the sha256 round loop (583 insns) and spectral-norm's `rowSum` loop
  (274 insns) are instruction-for-instruction the single-partition build's; no call to `rotr`,
  `State` or `a`.
- **Lost inlines against a true single partition** (benchmark program): 841 sites split →
  **237** at K = 40; sites with callees ≤ 32 insns 599 → 19. The rest are callees over K
  (> 64 insns: 140) and same-partition cost-model differences.
- **Lowering cost, self-compile** (alternated, 2 runs each): wall 19.32 / 19.45 s → 20.39 / 20.38 s
  (**+1.0 s, +5 %**), CPU 335 / 341 s → 363 / 359 s (+7.5 %), RSS 7.23 → 7.45 GB (+3 %), binary
  98.66 → 99.88 MB (+1.2 %). 660 leaf copies per partition on average (max 698), next to ~1,050
  `$cap` copies. Benchmark program: 8.29 → 8.43 s.
- **Self-compile runtime** (fe-opt-loop recipe, one run each): 65.72 s off → 64.57 s K = 40 (−1.2 s,
  within one-run noise); **fixed point OK** for both (output byte-identical to
  `eco-compiler-boot.mlir`).
- **Benchmark suite** (off/K40/off/K40, 74 workloads, all checks OK): geomean **K40/off 1.003**
  (flat). Moves beyond 3 % and twice the run-to-run noise:

| workload | K40/off | cause |
|---|---|---|
| spectral-norm | 0.859 | inlining (`SpectralNorm_a`, S0) |
| hot-lambda | 0.856 | layout: hot functions identical |
| sha256 | 0.94 (43.0 → 40.5 ms; noise 4.7 %, below the flag rule) | inlining (S0) |
| binary-trees | 1.065 | layout: hot functions identical |
| csv-parser, csv-split, dict, string-callbacks | 1.03-1.04 | code changed: P inlines more parser-combinator / `Dict.foldl` helpers (e.g. `CsvParser_row` 535 → 574 insns); not yet separated from layout |

Reading: P removes the inlining-sensitivity it targets (S0 cases, small-callee lost sites → ~0) for
+1 s of self-compile lowering, with the suite flat overall. Open before flipping the default: try
K = 24/32 (fewer copies, less lowering cost; S0's helpers are ≤ 35 ops) and check whether the
csv/dict 3-4 % is the extra inlining or layout (perf now works under `sudo -n perf`); then the §5
gates (bootstrap, eco-verify, `full`, `run-aot-e2e` with a forced split, `stress`) with the flag on.

### 2c. K sweep and the csv/dict attribution (2026-11-18)

K = 24/32/40/48/56 against off. The self-compile lowering alternated (off→56, then 56→off), each
build deterministic, off byte-identical to the shipped binary. The suite ran two passes per K, also
alternated. Lost sites are against the true single partition, benchmark program.

| K | lost sites | callee ≤ 32 insns | sha256 loop | self lowering wall (median) | CPU | binary | suite geomean K/off |
|---|---|---|---|---|---|---|---|
| off | 841 | 599 | `rotr`×6 + `State` | 19.43 s | 352 s | 98.66 MB | 1 |
| 24 | 415 | 161 | `rotr`×6 + `State` | 19.83 s (+0.4) | 362 s | 98.96 MB | 1.003 |
| 32 | 318 | 72 | `State` (35 ops) | 19.91 s (+0.5) | 365 s | 99.23 MB | 0.992 |
| 40 | 237 | 19 | = single partition | 20.32 s (+0.9) | 373 s | 99.88 MB | 1.001 |
| 48 | 179 | 11 | = single partition | 20.43 s (+1.0) | 374 s | 99.99 MB | 1.000 |
| 56 | 164 | 9 | = single partition | 20.55 s (+1.1) | 376 s | 100.07 MB | 0.998 |

spectral-norm is 0.863 at every K. Every K moves a set of small workloads by ±5–15 % with no
trend in K (matmul 1.07–1.15, hot-lambda 0.84–0.94, fib 0.83–0.99): layout.

**Remaining small-callee losses at K = 56** (9 sites): 5 are callees that are small in x86 but over
K in MLIR ops (`Prng_xorshift32` 79 ops / 11 insns, `UnicodeString_upperCase` 63 / 21); 4 are
`$cap` callees whose copies are dropped after the prepass (step 5, pinned). All 164 lost sites are
GC-free. The 130 sites with callees over 64 insns all call functions that are entirely inlined
away in the single-partition build but exported in the split: suspected loss of LLVM's
local-linkage, single-use bonus, not confirmed.

**csv/dict +3 % is layout, not inlining** (`sudo -n perf`, p0 vs K = 40, `perf stat` 2 runs each,
`perf record` 1 run each; scripts `/tmp/s08/perfk.sh`, `attrib.py`):
- Retired instructions are unchanged (csv-parser −0.0 %, csv-split +0.0 %, dict −0.0 %,
  string-callbacks −0.5 %) while cycles rise 1.7–3.2 %. The extra inlining adds no work.
- The sample delta lands on functions whose code is byte-identical between the builds or in the
  runtime (C++, identical code, moved addresses): dict +61 identical (`Dict_balance` 1405 insns
  in both) and +85 runtime, 0 in changed functions; csv-split +16 identical, +210 runtime, 0
  changed; string-callbacks +72 identical, +73 runtime, +14 changed. Only csv-parser has a changed
  hot function (`CsvParser_row` 535 → 574 insns, +53 samples), and it is offset by moves in
  identical functions.
- binary-trees (+6.6 % cycles, same instructions) is the same: +155 samples in
  `BinaryTrees_build`, identical 39 insns in both builds. hot-lambda's −13 % cycles is the
  reverse case (branch-misses −54 %).

### 2d. The large-callee losses are LLVM's single-use bonus (2026-11-18)

LLVM inliner remarks (`eco-boot-native -pass-remarks=inline -pass-remarks-missed=inline`) for the
single-partition build and the split (K = 128, `$cap` copies kept; 127 lost sites) show the cause.
LLVM gives an internal callee with one remaining use a 15,000 cost bonus ("last call to static"),
so the single-partition build inlines it whatever its size (e.g. `_tail_mono_inline_3513_42674$cap`
into `Bench_lambda_2702` at cost −13,850). In the split the same callee is exported, because a
declaration or a copy in another partition names it, so there is no bonus, and it is "too costly"
(cost 1,150 against 225). P makes this worse: copying a small caller such as `List_length` into other
partitions forces its single-use loop body to be exported. Of the 127 sites, 53 show the bonus
directly in the single-partition remarks and 74 are the same thing one level up (the callee was
bonus-inlined into a function that was then inlined into the census caller).

Experiment knobs in `ES` `buildPartitions` (default off, not for shipping as they are): a *solo
callee* is a GC-free function with exactly one direct call site in the whole module, no address
taken and no non-symbol reference (273 in the benchmark program, 3,495 in the self-compile).
- `ECO_SPLIT_SOLO_BONUS=N` with `ECO_SPLIT_SOLO_ATTR=<attr>` stamps `<attr>=N` on every solo callee
  (default attr `call-threshold-bonus`). `call-threshold-bonus` has no effect on the call to the
  stamped function: LLVM reads it from calls inside the body being costed. `function-inline-threshold`
  on the callee replaces the threshold at its call sites, which is what we want.
- `ECO_SPLIT_SOLO_COPY=1` copies a solo callee into each partition its caller is copied into.
- `ECO_SPLIT_SOLO_AFFINITY=1` gives a solo callee the owner of its chain's first non-solo caller
  (option R).
- `ECO_SPLIT_SOLO_DUMP=<path>` lists solo callees with their caller.

Benchmark program, K = 128 + `$cap` copies kept, against the true single partition:

| variant | lost sites | gained sites | program text insns | binary |
|---|---|---|---|---|
| base | 127 | 69 | 466,225 | 24.918 MB |
| `call-threshold-bonus=15000` | 194 | 136 | 473,248 | 24.947 MB |
| **`function-inline-threshold=15225`** (T1) | **31** | **24** | 472,840 | 24.942 MB |
| T1 + solo copy | 31 | 24 | 472,840 | 24.942 MB |
| T1 + affinity | 30 | 24 | 472,945 | 24.942 MB |
| `-inline-threshold=325` (global) | 117 | 145 | 471,565 | 24.938 MB |
| `-inline-threshold=500` (global) | 35 | 146 | 483,652 | 24.983 MB |
| single partition (reference) | 0 | 0 | 453,359 | |

T1 (15,225 = the default threshold plus LLVM's bonus) recovers 96 of 127 sites and gets much closer to
the single-partition inliner (gained 69 → 24); the global threshold either does little (325) or
inlines broadly where the single build does not (500, +3.7 % text). Solo copy and affinity add
nothing. T1's extra text is the solo bodies that stay emitted because they are exported (the
single-partition build deletes them); `--gc-sections` with function sections could drop the dead
ones. T1 is deterministic, all 74 workloads pass their self-check, and on the self-compile (K = 128 +
`$cap` copies, alternated, one run each pair) it costs about +0.15 s wall (20.57 / 20.66 →
20.76 / 20.76 s), +5 s CPU, binary 100.19 → 100.46 MB. The 31 left: 17 where the split inlines the
callee into some copies but not at the census caller, 14 where the callee has no body in the
caller's partition.

Both attributes together (`ECO_SPLIT_SOLO_ATTR=function-inline-threshold=15225,call-threshold-bonus=15000`,
"both"): 34 lost, 27 gained, 473,055 insns, i.e. the census sees about the same as T1.

Suite (2026-11-18, 74 workloads, all checks OK; off / base / T1 / both, two passes alternated
a: off→both, b: both→off; base = K = 128 + `$cap` copies kept):

| geomean | base | T1 | both |
|---|---|---|---|
| vs off | 0.999 | 0.999 | **0.990** |
| vs base | | 1.000 | 0.990 |

Workloads moving > 3 % against off and more than twice the noise (median of two, ratios to off):

| workload | off ms | base | T1 | both |
|---|---|---|---|---|
| spectral-norm | 92.0 | 0.859 | 0.859 | 0.859 |
| sha256 | 42.5 | 0.953 | 0.941 | 0.894 |
| floyd-warshall | 44.0 | 0.932 | 0.898 | 0.886 |
| matmul | 46.5 | 0.989 | 0.914 | 0.914 |
| hot-lambda | 108.0 | 0.880 | 0.884 | 0.949 |
| fib | 84.0 | 0.833 | 0.988 | 1.048 |
| levenshtein | 248.5 | 1.101 | 1.074 | 1.004 |
| csv-parser | 216.5 | 1.055 | 1.072 | 1.028 |
| decoded-snapshot | 101.5 | 1.064 | 1.044 | 1.000 |
| string-append / -concat / -join / -callbacks | 198-331 | 1.03-1.04 | 1.02-1.05 | 0.99-1.02 |
| binary-trees | 107.0 | 0.977 | 1.014 | 1.037 |
| dict-char-pairs | 248.0 | 0.988 | 1.012 | 1.040 |

**The "both" 1 % is layout, not inlining** (checked with `sudo -n perf`). The T1 and "both" binaries
have the same 8,570 functions and differ in only three program bodies (`Bench_lambda_2107$cap`
136 → 221 insns, `Sudoku_assign` 87 → 163, `Sudoku_eliminate` 283 → 337), none of them in a moved
workload's profile; the growth shifts the C++ runtime by 0x2f0 bytes. levenshtein and csv-parser
retire the same instructions (103.744e9 → 103.748e9; 22.447e9 → 22.446e9) in 4.7 % / 3.2 % fewer
cycles, with every saved sample in byte-identical functions (levenshtein: −344 identical program, −639
runtime, e.g. `Allocator::resolve`, `recordAllocation`; csv-parser: −166 identical program, −49
runtime; 0 in changed functions). So base, T1 and both are runtime-equivalent on this suite; a few
hundred bytes of runtime shift moves the suite geomean by about 1 %, so geomean differences of that
size need counter attribution. The real runtime effects are the S0 inlining fixes (spectral-norm,
sha256), present in all three. T1's case is split invariance (lost 127 → 31, gained 69 → 24, at
about +0.15 s self-compile lowering and +0.27 MB), not a measured speedup. Self-compile runtime not
measured.

### 2e. Alignment runs and the new defaults (2026-11-18)

K = 128 + `$cap` copies kept + T1, under four alignments (two alternated suite passes each, medians in
`/work/t1-k128-capcopy-alignment.csv`), compared with `/work/without-pr.csv` (before PR #17) and the PR #17
alignment runs (`/work/alignment.csv`): every PR #17 variant is about 0.90 geomean of the baseline, the spread
between them is layout. The plan-08 builds are the only ones where spectral-norm matches the baseline (1.000
vs 1.15-1.17) and sha256 halves its regression (+8-11 % vs +17-19 %). Best overall: innermost loops at 32 B
("best a32": geomean 0.898, 7 workloads > 3 % slower; levenshtein +14 % and sha256 +11 % remain).

**Made default** (2026-11-18): `ECO_SPLIT_IMPORT_LEAF_MAX_OPS` 128, `ECO_SPLIT_KEEP_LEAF_CAP_COPIES` on,
`ECO_SPLIT_SOLO_INLINE_THRESHOLD` 15225 (`function-inline-threshold` on owned and copied definitions of solo
callees, `cgu` split only; the §2d experiment knobs `ECO_SPLIT_SOLO_{BONUS,ATTR,COPY,AFFINITY,DUMP}` are
removed), and 32 B innermost-loop alignment. The alignment is an X86 command-line option with no
`TargetOptions` field, and LLVM's option registry does not hold it outside `cl::ParseCommandLineOptions`, so
`eco-boot-native` appends `-x86-experimental-pref-innermost-loop-alignment=5` to its own argv unless given
(`withDefaultCodegenArgs`), and the `eco` driver, which never parses LLVM options, parses that one argument
once (`setDefaultCodegenOptions`). With all four off (`=0` / `--x86-...=4`) the benchmark program is
byte-identical to the shipped binary; with the defaults it is byte-identical to the measured "best a32".
Self-compile: lowering 20.78 s (≈ +1.35 s vs the same input with plan 08 off; `backend-opt-loop.md` P08),
self-compile runtime 64.33 s (−1.73 s vs pr17, fixed point; `fe-opt-loop.md` p08).

## 3. Options

### P (primary): copy small GC-free callees into the partitions that call them

Extend EcoSplit's import rule beyond `$cap`:
- **Candidates:** defined functions stamped `gc-leaf-function` by the MLIR GC-free propagation,
  with at most `K` MLIR ops (start at the size that covers S0's callees; e.g. 40 ops, about the
  64-instruction `$cap` threshold), not address-taken by `Address` edges only, reached from an
  owned body by a `Call` edge.
- **Copies:** cloned as `available_externally`, like `$cap` imports; their out-edges get
  declarations by the existing rule.
- **Lifetime:** these copies are NOT dropped after the `$cap` prepass. They contain no statepoint
  (GC-free), so they may pass RS4GC unchanged and reach the post-RS4GC `-O2` inliner, which makes
  the same cost-model decision it makes when the body is owned locally. Whatever is not inlined
  is dropped by LLVM (`available_externally` is never emitted).
- **Invariant change:** CGEN_083's "no available_externally function may reach RS4GC" becomes "no
  available_externally function that is not stamped gc-leaf-function may reach RS4GC", with the
  hard error kept for every other copy. The RS4GC flavours must be checked to leave gc-leaf bodies
  untouched (they have no `gc` strategy calls to rewrite); a validate-build assertion that a copy
  is still statepoint-free after RS4GC pins it.
- **Why primary:** it handles helpers with many callers (`rotr` is called from more than one
  function, so no single owner can be right for all), and it reproduces exactly the
  whole-module inliner's decision instead of introducing a new heuristic.
- **Costs:** more IR per partition (bounded by `K` and by the reachable set); slightly more
  translate/opt CPU. Must not move the lowering wall beyond the backend loop's noise floor
  (`benchmarks/backend-opt-loop.md` §4, 1 s or 1 %).

### Q (secondary, only if S0/S1 show it matters): small GC-bearing spec helpers

A small spec that may allocate cannot cross RS4GC as a copy. Its only safe inlining point is the
pre-RS4GC prepass, so this extends the prepass from `$cap` to small specs (same threshold
machinery, same slot-cast-barrier requirement, same import/drop lifecycle as `$cap` copies).
- **Caution:** this changes codegen on the unsplit path too (the prepass runs whole-module there),
  so it is a codegen-quality change, not only a split-invariance fix. It needs the recursive-tax
  gate and its own measurement.

### R (complement, cheap): small-callee affinity in ownership

After LPT, move each small callee with exactly one hot caller into that caller's partition, under
the 1.05 × mean balance cap. This is plan 06's D1/D3 restricted to small callees.
- It only helps single-caller helpers, which P already covers without moving ownership, and plan
  06 S6 measured D3 FLAT on the self-compile. Build R only if S1 shows a large lost-inline count
  that P cannot reach (e.g. GC-bearing single-caller helpers, where it would substitute for Q).

## 4. Steps

1. **S0, S1, S2** (above). Done 2026-11-18, §2a: unsplit buys 1.8 % geomean, sha256 and
   spectral-norm are P-class; continue with P.
2. **P behind an env flag** (`ECO_SPLIT_IMPORT_LEAF_MAX_OPS`, 0 = off). Built and measured at
   K = 40, 2026-11-18, §2b; gates not yet run. Original spec: candidate selection in
   `ES` `buildPartitions`, the lifetime change in `EB`'s partition worker (keep gc-leaf copies past
   the prepass drop), the RS4GC guard narrowed, the validate assertion. Measure:
   - S1 lost inlines (target: GC-free lost inlines → ~0 for callees ≤ K);
   - lowering wall and per-worker CPU (backend loop, one run, `p2`-equivalent input regenerated
     from today's tree);
   - the benchmark suite, twice, on two different builds of the same source with a forced layout
     perturbation (e.g. `--x86-experimental-pref-innermost-loop-alignment=5` vs default), to check
     that sha256-class swings are gone;
   - self-compile runtime (fe-opt-loop, one run).
3. Choose `K` from step 2 (smallest that removes the observed lost inlines without wall cost) and
   flip the default on.
4. **Q or R** only if step 1 showed lost inlines that P cannot reach and that carry runtime weight.
5. **Keep GC-free `$cap` copies to `-O2`. Built 2026-11-18 behind `ECO_SPLIT_KEEP_LEAF_CAP_COPIES`
   (default off, `cgu` only); gates not run.** P excludes `$cap`
   callees, and `$cap` import copies are dropped after the prepass. When the prepass does not
   inline a site (e.g. a signature-mismatched site, not yet checked), the post-RS4GC `-O2`
   inliner never sees the body, although the single-partition build inlines it there because
   the callee is gc-leaf. At K = 56 this is 4 of the 9 remaining lost sites with callees
   ≤ 32 insns in the benchmark program, e.g. `__closure_wrapper_typed_Bench_lambda_2828$cap ->
   Bench_lambda_59$cap` (3 insns). Fix: in `EB`'s post-prepass drop loop, keep a `$cap` copy
   that is stamped `gc-leaf-function` (widen `isLeafImportCopy` and the RS4GC guard to match;
   CGEN_083 wording follows). Low expected runtime weight; measure with the S1 census.
   Built as specified: `isLeafImportCopy` is now any `available_externally` copy stamped
   `gc-leaf-function`, the drop loop keeps a `$cap` one only when the flag is on under `cgu`, and
   `checkStampedBodies` no longer needs its linkage exemption (every surviving copy is stamped).
   Flag off: benchmark program byte-identical at K = 0 and K = 56. Flag on: deterministic (K = 128),
   all 74 workloads pass their self-check at K = 56 and K = 128. Lost sites against the true single
   partition, benchmark program, flag off → on:

   | K | 0 | 40 | 56 | 64 | 96 | 128 | 192 | 256 |
   |---|---|---|---|---|---|---|---|---|
   | off | 841 | 237 | 164 | 151 | 141 | 134 | 134 | 134 |
   | on | 834 | 230 | 157 | 144 | 134 | 127 | 127 | 127 |

   The flag removes the same 7 sites at every K, including all four small `$cap` sites. The 12
   `$cap` sites left are large loop bodies (`_tail_go_40427$cap` 274 insns,
   `_tail_mono_inline_3513_42674$cap` 412 insns), which the single-partition build inlines into
   their callers and the split build does not even when the body is present; that is the
   large-callee class (§2c). P saturates at K = 128: K = 192 and 256 copy almost nothing new.

## 5. Gates

- `bootstrap` (4b and 8c fixed points) and `eco-verify`.
- `full` (JIT E2E), `run-aot-e2e` normal and with a forced split (`ECO_SPLIT_MIN_FNS` low), `stress`.
- G2-style body identity: split vs translate-whole, every function body equal modulo phi order
  (copies are inlined or dropped, never emitted).
- Determinism: two lowerings byte-identical at the IR level (`--emit=llvm`).
- Recursive tax (backend loop §6.4) if the default changes codegen: ≤ 3 %.
- Invariants: amend CGEN_083 (the RS4GC rule and the import rule), and CGEN_072 if the copy
  carries the stamp across a new boundary.

## 6. Risks

- **A wrong gc-leaf stamp becomes a miscompile in more places.** Today a wrongly stamped callee is
  only inlined post-RS4GC within its own partition; with P it is inlined into every calling
  partition. The MLIR producer is the same, but the validate twin (whole-module) must stay on in
  validate builds.
- **RS4GC flavours that touch every function.** If any flavour rewrites a gc-leaf body (e.g. adds
  a `gc` attribute or barriers), the "copy survives RS4GC" premise fails. S-step: run the
  validate assertion over the self-compile before flipping anything.
- **IR growth.** `K` bounds each copy; the reachable set bounds the count. Measure imports per
  partition (`ECO_MLIR_SPLIT_STATS`) at each `K`.
- **Benchmarks may still swing** from layout alone (the alignment experiment showed ±10 % across
  rebuilds on small workloads). P removes the inlining part of the noise, not the placement part.

## 7. Open questions

- Should `K` be measured in MLIR ops (known at split time) or LLVM instructions (what the inliner
  sees)? Plan 06 S4b's fitted op→instruction table could convert, but ops are probably enough for
  a size cap.
- Is spectral-norm the same class? Yes (§2a S0): `SpectralNorm_a`, GC-free, 18 ops.
