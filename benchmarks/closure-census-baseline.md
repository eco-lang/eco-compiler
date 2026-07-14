# Closure allocation census — baselines (H0.3)

Plan: `plans/hof-elimination-closure-alloc-reduction.md`. Started 2026-07-13,
alongside H1 (let-callee forwarding + chain-aware closure DCE), so the numbers
below are the **post-H1** baseline; the pre-H1 pipeline had no measurement at
all.

## Instruments

- **Runtime (dynamic)**: `ECO_CLOSURE_STATS=1 <binary> 2> census.log` — the
  runtime counts every closure allocation keyed by evaluator fp
  (`runtime/src/allocator/RuntimeExports.cpp`, dump at exit incl. on signal
  paths' atexit). Symbolize with `benchmarks/closure-census.sh <binary> census.log`.
  `creates` = papCreate paths (incl. fast/slow split + group alloc);
  `extends` = eco_pap_extend copy-allocations.
- **Compiler (static)**: `ECO_INLINE_REPORT=1` (or `inline.report` in
  eco-config.json) prints after the inline+simplify phase:
  `inline-simplify: inlined= beta= betaForwards= letDCE= closureDCE=
  closuresRemaining=` plus top-20 inlined callees. `closuresRemaining` counts
  `MonoClosure` nodes in expression position post-inline (top-level function
  closures excluded — they lower to `func.func`, not allocations).
- **MLIR (static)**: compile with `--text-mlir` and
  `grep -c eco.papCreate` (bytecode `.mlir` is binary — text form required).

## Adversarial probe results (2026-07-13, post-H1)

| Test | betaForwards | closureDCE | closuresRemaining | papCreate | note |
|---|---|---|---|---|---|
| HofLetClosureForwardTest | 1 | 0 | 0 | 0 | let-λ under `if`, Int+Bool captures, forwarded |
| HofPipeLambdaTest | 4 | 0 | 0 | 0 | 4-stage `\|>` chain with λ literals — fully flattened |
| HofClosureDCETest | 0 | 1 | 0 | 0 | dead let-λ dropped (was categorically kept pre-H1) |
| HofSinkGuardTest | 1 | 0 | 3 | 6 | guard holds: λ used inside another λ NOT forwarded |
| HofForwardGCPressureTest | 1 | 0 | 0 | 2 | residual = zero-capture `Basics_add` PAPs for `List.foldl` (H4.2/H5 class) |

Letrec safety pins (post chain-level fix — forwarding correctly refuses):

| Test | betaForwards | closuresRemaining | note |
|---|---|---|---|
| LetRecClosureTest | 0 | 1 | self-recursive let closure kept |
| MutualLetRecClosuresTest | 0 | 4 | mutual pair ×2 kept (earlier-sibling refs) |
| MutualLetRecNestedTest | 0 | 3 | nested mutual kept |
| ProcessSpawnKillHalfTest | 0 | 10 | recursive `go` kept |

Key confirmations against the plan's diagnosis:

- `apR` **does** inline at the default threshold (pipe test: `inlined=10`,
  incl. the four `apR` specs) — the blocker was the missing beta-completion,
  exactly as §4 of the plan claims. Note: fully-inlined specs can leave a dead
  `func.func` definition behind (a `Basics_apR_$_N` with a generic
  `eco.papExtend` body survives in HofPipeLambdaTest's module) — dead-spec
  pruning fodder, not an allocation.
- The dominant residual class after H1 is **zero-capture kernel-wrapper PAPs
  passed to recursive HOFs** (`Basics_add` → `List.foldl`): the H4.2
  (interning) / H5 (capture flattening) classes.

## Corpus / workload baselines

- E2E corpus (genuine recompile — all 941 test `.elm` touched first,
  2026-07-13): **1595/1595 passed** with H1 active everywhere.
- elm-tests: **12991 passed / 12 failed — byte-for-byte the known baseline
  state** ("12991/12"). The 12 are pre-existing typecheck-level failures
  (11× POST_010 node-type-grounded/vars-constrained fixtures, 1× golden
  constraint fingerprint `if-chain`) whose code paths the H0/H1 diff cannot
  reach. The 3 H1-caused failures (CGEN_056 on SKI + identity-composition
  fixtures, CallInfo) were fixed by the two forwarding guards: saturated
  uses only, ground (non-function) result type only.
- **Self-compile (stage 7a) dynamic census: PENDING** — run
  `ECO_CLOSURE_STATS=1` on the stage-7a native compile and record the top-20
  table here (needs the bootstrap chain; several minutes). This is the
  H2-targeting input.

## H2 matrix (2026-07-13, JS-hosted compiler self-compile to MLIR)

Workload: `build/compiler/build-kernel` (`src/Terminal/Main.elm`,
`--local-package eco/kernel=/work/eco-kernel-cpp`,
`NODE_OPTIONS=--max-old-space-size=12288`). "Warm" = second consecutive run
of the same config (a config flip rewrites `d.dat` and forces a full
front-end recompile, so interleaved runs are cold-only).

| config | warm wall | inlined | betaForwards | closuresRemaining | .mlir size |
|---|---|---|---|---|---|
| hofThreshold=10 | 93.4 s | 63,460 | 1,160 | 14,525 | 12.00 MB |
| hofThreshold=25 | 98.8 s | 65,450 | 1,571 | 15,894 | 12.32 MB (+2.7%) |
| hofThreshold=40 | 98.4 s | 73,408 | 2,154 | 19,004 | 13.15 MB (+9.6%) |
| hof=25, fpi=6 | — | — | — | — | OOM at 14 GB node heap |

~~Cold interleaved timing showed no compile-time signal~~ — **RETRACTED**:
all four interleaved runs OOM-crashed (12 GB node heap is insufficient for
COLD self-compiles; `/usr/bin/time` still prints a wall line). Cold runs
need `--max-old-space-size=14336`; interleaved timing is impossible on this
host anyway because a config flip forces a cold run.

The upper matrix rows predate the `exactOnly` soundness containment
(hofBudget candidates inline at exact application only — the partial
rebuild's re-staged closure trips the runtime typed-apply arity assert,
`spliceArgsForSaturatedCall`; CombinatorB*/SolverLayoutStepMonadTest pins).
Most of hof=25's +35% betaForwards came from the unsound partial path.
Final numbers, all H2 machinery in (warm = 2nd consecutive same-config run):

| config (final) | warm wall | inlined | betaForwards | closuresRemaining | .mlir size |
|---|---|---|---|---|---|
| hofThreshold=10 | 95.9 s | 63,470 | 1,392 | 14,094 | 11.90 MB |
| hofThreshold=25 | 100.7 s | 63,666 | 1,418 | 14,118 | 11.91 MB (+0.11%) |

(baseline betaForwards rose 1,160 → 1,392 from the threshold-independent
H2.0 machinery: case-body inlining, let-of-closure flattening, let-callee
hoisting.)

**Decision: default `hofThreshold = 25`.** On the pipe-heavy self-compile
workload the incremental win is small (+1.9% betaForwards) because
`m |> andThen λ` partially applies `andThen` and exactOnly blocks it; on
direct-application HOF code the collapse is total (AndThenProbe direct
chain: zero papCreate, pinned in the corpus under the default). Costs:
+0.11% size, warm-wall delta +5.0 s on single samples (run-to-run noise
≈ ±3 s — treat as ≤5%, unconfirmed). 40 rejected (+9.6% size pre-exactOnly);
fpi=6 rejected (OOM even at 14 GB heap). The pipe-shape win unlocks when
the partial-rebuild staging fix lands (plan H2 follow-up).

Notes:
- `closuresRemaining` RISES with the budget: inlining duplicates the
  closure-creation SITES of data-escaping callbacks (Bytes.Decode-style
  bodies). Static sites ≠ dynamic allocations; the dynamic self-compile
  census (ECO_CLOSURE_STATS on a native stage-7a run) remains the pending
  measurement for the true allocation delta.
- The corpus-wide dynamic census via the JIT harness does NOT work: JIT
  test allocations don't aggregate into the parent process census (only
  in-process unit-test allocs appear). Use AOT binaries.
- The first matrix runs OOM'd node's default heap and dumped ~47 GB of core
  files into `build/compiler/build-kernel/`, filling the disk and silently
  truncating corpus artifacts ("Symbols not found: _mlir_main" failures).
  If self-compile runs abort, check `core.*` and `df` FIRST.

## Known measurement gotchas

- The E2E harness compile cache is mtime-only and env/config-blind
  (`test/ElmE2ETestBase.hpp` `needsRecompile`): touch all test `.elm` before
  any corpus run whose compiler/flags changed.
- The harness swallows compiler-census stderr; run `ECO_INLINE_REPORT=1`
  compiles manually (`node compiler/bin/index.js make <file> --output=… --text-mlir`).
- JIT test runs link the runtime in-process: `ECO_CLOSURE_STATS=1` on the test
  binary yields one aggregate dump at exit (all tests summed), and fps can't
  be symbolized via `nm` for JIT'd code — use AOT binaries for per-site tables.
