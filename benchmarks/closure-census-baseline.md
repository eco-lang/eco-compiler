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

## Known measurement gotchas

- The E2E harness compile cache is mtime-only and env/config-blind
  (`test/ElmE2ETestBase.hpp` `needsRecompile`): touch all test `.elm` before
  any corpus run whose compiler/flags changed.
- The harness swallows compiler-census stderr; run `ECO_INLINE_REPORT=1`
  compiles manually (`node compiler/bin/index.js make <file> --output=… --text-mlir`).
- JIT test runs link the runtime in-process: `ECO_CLOSURE_STATS=1` on the test
  binary yields one aggregate dump at exit (all tests summed), and fps can't
  be symbolized via `nm` for JIT'd code — use AOT binaries for per-site tables.
