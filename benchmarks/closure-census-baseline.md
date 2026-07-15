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
  **CAVEAT (found 2026-07-14):** the text dump is FRONT-END output — the
  `EcoPAPSimplify` MLIR pass (default pipeline, P1 saturated-single-use
  elision + P2 chain fusion) runs AFTER it, so static papCreate counts
  OVERSTATE runtime allocations. Use `ECO_CLOSURE_STATS` for real deltas.

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

### H2.5 step 1 (application merging), same workload

| config | warm wall | betaForwards | partialMerges | closuresRemaining | .mlir size |
|---|---|---|---|---|---|
| hof=25 + merging | 95.6 s | 1,655 | 5,188 | 13,885 | 11.80 MB |

Application merging (`(f a1s) a2s` ⇒ one call when total ≤ arity, plus
strictly-partial let-bound global calls forwarded into their single
callee-position use) reunites the pipe-shaped spine: 5,188 merges on the
self-compile, betaForwards +19% over the hof=10 baseline, artifact SMALLER
than baseline, wall time back at baseline. The pipe shape
`m |> Maybe.andThen λ` now collapses to zero papCreate (AndThenProbe pins
it module-wide under the default config).

### H2.5 step 2 (faithful residual type + guard relaxation)

| config | betaForwards | partialMerges | closuresRemaining | .mlir size |
|---|---|---|---|---|
| + step 2 | 1,660 | 5,188 | 13,880 | 11.80 MB |

The partial rebuild's type bug (double-wrapped arrow — `peelCallResult`
already returns the residual arrow and the rebuild wrapped it again) is
fixed; H1's ground-result forwarding guard is removed (curried let-lambdas
collapse — HofCurriedForwardTest, zero papCreate); `exactOnly` is retained
permanently by design (partials of globals stay PAPs per mono-uncurry — the
runtime typed-apply cannot chain over-application of re-arited closures).
Self-compile delta is small (+5 betaForwards — curried let-lambdas are rare
in the compiler); the value is soundness surface + curried-code collapse.
Runtime-surviving literal-partial residuals are pinned by
HofResidualPartialTest. E2E 1602/1602; elm-tests 12991/12 identical set
with the CGEN_056 fixtures reachable again.

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

## H3 (LSS-on re-gate + solver-implies-LSS, 2026-07-14)

First-ever flag-on corpus run against the H1–H2.5 inliner:
`ECO_MONO_ENGINE=solver ECO_MONO_LSS=1` → **1602/1602** (genuineness proven:
harness artifact byte-identical to an explicit solver+LSS compile, ≠ subst).
`defaultLss.enabled` flipped to True — inert for the default subst engine,
but every solver run now gets LSS without flags. Engine default stays subst
(JS-hosted solver self-compile ≥12× — monosolver plan owns that blocker).

Flag-on probe censuses (post H1–H2.5 — fully-collapsed modules have nothing
left to stamp, exactly as intended):

| probe | dispatchUpgraded | note |
|---|---|---|
| LssSingletonFastDispatchTest | 1 | singleton pin intact |
| LssVerbatimCopiesFastDispatchTest | 1 | LSS_009 verbatim-copy stamping intact with new inliner |
| AndThenProbe | 0 | spine fully inlined away pre-AbiCloning |
| CombinatorBComposeTest | 0 | PAP shapes, correctly unstamped |

The big flag-on census (self-compile scale) awaits a native solver run.
EngineDiff note: the flip surfaced an implicit coupling — Diff.elm "forced
LSS off" by USING `Config.defaultLss`; it now forces `enabled = False`
explicitly. Residual-rebuild closures also now clear
srcLambda/closureKind/captureAbi (LSS_009: residuals are not verbatim
copies; impersonation prevented before flag-on exposure).

## H4 (2026-07-14): P4 multi-use elision + zero-capture interning

- `EcoPAPSimplify` P4: multi-use papCreates whose every use is a saturated
  typed papExtend are elided (each use → direct call, capture forwarded).
  Engine-independent (needs `remaining_arity`, not LSS stamps). Structural
  pins in `test/codegen/pap_simplify_multi_use_*.mlir`.
- `eco_intern_closure0`: zero-capture creates (the duplicated
  `Basics_add`/`List_cons` wrapper PAPs this doc's probes identified)
  allocate ONE permanent singleton per wrapper (HEAP_033).
- **Measurement note**: static text-MLIR counts see neither (both are
  post-front-end); the JIT harness census cannot aggregate per-test JIT
  allocations. The dynamic magnitude of both belongs to the pending
  native-binary census run.
- Trap fixed en route: `ecoc -emit=mlir-eco` ran NO passes (dumped input) —
  all prior structural mlir-eco CHECKs were vacuous; and the codegen
  harness RUN-parser substring-matched `mlir-eco` as `mlir`. Both fixed —
  structural pass tests are now real.

## H5 (2026-07-14): recursive-HOF loopification (self-compile, warm)

| metric | H2.5/H4 baseline | + H5 |
|---|---|---|
| loopified | — | **779** (of 1,980 eligible tail-func specs) |
| beta | 1,660 | 2,441 |
| closuresRemaining | 13,880 | **13,152 (−5.2%)** |
| .mlir size | 11.80 MB | 11.99 MB (+1.6%) |

Call-site loopification (engine-independent, default-on): a saturated call
of a tail-recursive HOF with a lambda LITERAL becomes a local specialized
loop; the lambda's papCreate disappears at the front end and the loop
shell (no self-capture for pure tail recursion) is elided by EcoPAPSimplify
P1 — `HofFoldlLoopifyTest`'s module compiles to ZERO papCreates post-pass.
The 779 sites are the `List.foldl/map`-class population every earlier
phase had to walk around. Remaining for v2: variable-argument callers
(LSS-annotation route), non-tail HOFs (`List.foldr`), multi-stage literals.

## H6.0 survey (2026-07-14)

### H6.0c — static residual taxonomy (self-compile, post-inline graph)

`residual closures:` line of `ECO_INLINE_REPORT=1` (13,165 total):

| bucket | count | share | meaning / actionability |
|---|---|---|---|
| let-bound | 6,752 | 51.3% | bound closures H1 kept (multi-use or refused positions). OVERSTATES final allocations — the all-saturated-use subset is elided downstream by P1/P4, which this static view cannot see. Needs the dynamic census to rank truly. |
| arg-to-global | 4,086 | 31.0% | args to non-tail function specs — `List.foldr`-class + general HOFs (H6.1 candidates) |
| arg-to-ctor | 1,204 | 9.1% | stored into data constructors — SEMANTIC, permanently out of scope (as predicted) |
| value | 633 | 4.8% | closure-typed results/branches |
| arg-to-tailfunc | 335 | 2.5% | tail-func HOFs H5 can't loopify (cost/analysis) |
| arg-to-loopifiable | 67 | 0.5% | loopifiable specs, call site failed qual (non-literal/multi-stage) — H5 v2's ceiling is tiny on this workload |
| stored-data / kernel / local / callee | 88 | 0.7% | long tail (callee=1 confirms beta converges) |

### H6.0b — flag-on decline histogram (solver+LSS module batch)

Every single `declinedShape` in the batch is **arity** (PAP consumption);
bucketMiss = layout = char = nonArrow = 0 across all probes. Dispatch
coverage's blocker is PAP-shaped consumption, NOT layout diversity — the
wrapper-home/local-multi/layout items rank BELOW pap-shape handling.
Second finding: the H2–H5 inliner phases have quietly ERODED stamp counts
on the Lss pins (e.g. LssSingletonFastDispatchTest now `dispatchUpgraded=0`
— its annotated call is inlined away entirely, so dispatch became moot at
sites where allocation elimination succeeded). Old dispatch-coverage
numbers are dead; sites that survive still stamp.

### H6.0a — dynamic census on native binaries

Pipeline validated end-to-end (eco-boot-native lowering of current-compiler
.mlir → ELF → `ECO_CLOSURE_STATS=1` → `benchmarks/closure-census.sh`, which
needed two portability fixes: no `-o pipefail` with early-exit awk over nm,
and hex-string GLB lookup since mawk lacks strtonum). First result:
`HofForwardGCPressureTest` native runs its 20,000-iteration workload with
**ONE closure allocation total** — `__closure_wrapper_typed_Basics_add_$_9_ri`,
created once by H4.2's interning.

**Survey found a latent Char-capture miscompile.** Lowering the H6.0-era
self-compile artifact natively hit `Calling a function with a bad
signature` at LLVM translation — 1 call among 626,678: a loopified
taildef, escaped as a value from a Char spec of `List.member`, whose
outlined `$cap` shell typed its capture `!eco.value` while the papCreate
site passed raw `i16` with `unboxed_bitmap=3`. Root cause (predates the
HOF work): `mlirTypeToApproxMonoType` in `Expr.elm` kept a stale
pre-i16-Char `I32 -> MChar` arm, so I16 fell to boxed `MUnit` — its ONLY
consumer is escaped-taildef capture typing, and no corpus/self-compile
program had ever reified a Char-capturing taildef until H6.0's new
compiler code perturbed the workload into producing one. Repro
`CharCaptureEscapedTailDefTest.elm` SEGFAULTS pre-fix (generic apply reads
the closure per the i16 create-site bitmap, shell compiled boxed → Char
dereferenced as pointer) — i.e. the JIT path silently miscompiled this
shape too. Fixed (`I16 -> MChar`). Diagnosis recipe: dump final IR with
`--mlir-print-ir-after-all --mlir-print-ir-tree-dir=<dir>` (module dump
prints in GENERIC form when ops are invalid — itself a tell that the
pipeline runs unverified) and scan `llvm.call` arg types against
`llvm.func` decls.
### H6.0a flagship — native eco compiling the full compiler (2026-07-14)

Post-fix `eco-h6b.mlir` lowers clean; the resulting native eco (60.7MB)
recompiled the whole compiler from a cold project cache and produced a
**byte-identical artifact** to the JS-hosted compiler's (fixed point holds
through H0–H6.0 + the Char fix). Census (`ECO_CLOSURE_STATS=1`, dump
aggregate line): **creates=403,903,871 extends=523,370,892 distinct=7,115
(overflow=91)** for one full compile.

Headline structure:

- **Extend traffic is the bigger half and it is ALL on interned
  singletons**: 3,676 of 7,115 evaluators have creates≤2 (H4.2 interning
  — every zero-capture closure is now created exactly once), and they
  carry 523.35M of 523.37M extends (99.996%). Top: `Bitwise.and` 156M,
  `Bitwise.shiftLeftBy` 94M (Dict/hash kernels), `TypeCheck.IO.map` 13M,
  `TypeCheck.IO.traverseList` 6.8M. Each papExtend allocates a PAP node —
  generic apply of known-arity global/kernel PAPs is now the single
  biggest allocation source (~56% of events).
- **Creates are concentrated capture-carrying continuations**: top-10 =
  36%, top-50 = 68%, top-200 = 89% of 403.9M. The top block is the
  typechecker's IO monad: `Terminal_Main_lambda_8274/8268/8605` (34M/18M/
  7M — `Array.get`+crash-guard UnionFind/IORef readers), `lambda_8286`
  (17.7M — `readIORefPointInfo/Descriptor` + `TypeCheck.IO.andThen`),
  `lambda_8179` (10M — `TVar` ctors + andThen + `termToCanType`), plus
  `List.cons` builder lambdas (11M/8M). These are monadic-bind
  continuations that ESCAPE into the returned IO value — the
  arg-to-global/stored-data residual classes of H6.0c, not inliner
  misses.
- Symbolizer caveat: a few rows resolve to `_GLOBAL__sub_I_StackMap.cpp`
  (GLB fallthrough for local symbols) — read neighbors, not those rows.
  The raw log is NOT creates-sorted; sort before `closure-census.sh`
  (which takes the first N lines).

## H6.1 (2026-07-14) — saturated PAP-chain elision, measured

Same artifact (`eco-h6b.mlir`), same workload (native eco compiling the
full compiler, cold project cache), backend F1+F2 only:

| | creates | extends | distinct |
|---|---|---|---|
| pre-H6.1 | 403,903,871 | 523,370,892 | 7,115 |
| F1+F2 | 403,903,415 | **139,999,056 (−73.3%)** | 6,660 |

Output artifact BYTE-IDENTICAL both runs. Bitwise/Array extend traffic
(156M+94M) eliminated entirely; total PAP events −41%. Post-F1/F2 top
extends: `applySubstPure` 11.3M / `typeEncoderS` 10.3M /
`typeHasResidualNumber` 9.5M (HOF-arg partials applied generically) +
`TypeCheck.IO.map`/`traverseList` (~20M, the H6.2 monad). F3 (front-end
point-free merge) additionally intrinsifies the `<|` chains at the Mono
level (MergeProbe: `partialMerges=2`, `eco.int.and` ×3); its census
delta rides the eco-h61 artifact.

Final F1+F2+F3 run (`eco-h61.mlir` — note: different workload, the
compiler source now includes the H6.1/H6.2 code itself): creates
405,020,772 / extends 140,416,526 / distinct 6,664; native output
BYTE-IDENTICAL to the JS-hosted compiler's. F3's runtime effect is
subsumed by F1/F2 (its value: `partialMerges` 5,188 → 6,125, `<|` chains
intrinsify at Mono level, arg-to-global taxonomy −744). U0 (`function
results:`): 1,211 function-typed-result specs; consumption = returned
700 / let-bound 471 / applied 410 / arg 148 — ~60% of sites escape
across function boundaries, confirming arity raising as the necessary
H6.2 lever.

### H6.2 layers 1–3 (2026-07-15)

Layer 1 (unconditional): cross-stage batches in the staged-known call
emission no longer claim `_capture_abi`/typed `remaining_arity`/direct
`_call_kind` — the staged-wrapper contract only holds for
compiler-materialized wrappers (self-compile contained ZERO of the old
stamps). Layer 2 verdict: **standalone flag-off bug confirmed**, plus a
second one — staged-result specs were TYPE-FLATTENED at codegen
(`mk : Int -> (Int -> Int)` emitted as `(i64)->(i64)`), **FIXED 2026-07-15**:
`generateTailFunc` typed a tail-func spec's return via
`decomposeFunctionType` (drops ALL arrow args to the leaf), collapsing the
returned closure when a def has fewer value params than arrow args;
`Context.residualResultType` now re-curries the un-consumed args. Pin:
`test/elm/src/StagedResultTest.elm` (E2E, 44/32/1000); gate 1616/1616.
Layer 3 (unconditional): `ForwardClosure` now betas the FIRST
stage of a multi-stage single-call application and re-applies the rest —
the stall that kept `f a s1` alive. Gate 1613/1613 with both
unconditional layers on the default path. RaiseProbe flag-on:
`closuresRemaining 3 → 0`, pap ops 12 → 6, correct output.

Flag-on U2b measurement (2026-07-15, post layer-4 fix — see below):

| native eco, full-compiler compile | creates | extends | total events |
|---|---|---|---|
| flag-off (F1+F2+F3) | 405,020,772 | 140,416,526 | 545.4M |
| **flag-on (U2b)** | **261,542,727 (−35.4%)** | **400,257,605 (+185%)** | 661.8M (+21%) |

Flag-on output BYTE-IDENTICAL to the JS-hosted flag-on compiler
(fixed point holds). The creates win is exactly the H6.2 target (bind
continuations die), but every ESCAPING bind site (60% per U0) now pays a
PAP-extend on the interned raised combinator instead — top extends are
the raised `andThen` specs themselves (41.2M/12.3M/9.9M) plus `apR`
pipe-styling (20.6M; `x |> andThen k` adds an extend per pipe). 99.995%
of extends sit on interned singletons. **Net: −0.9% artifact,
−35% creates, +21% total allocation events → the flag stays OFF.**
Follow-up levers: (a) single-alloc emission for raised-partial bind
sites (create+extend fused into one PAP-with-args alloc → escaping
sites reach parity and the net flips negative); (b) selective raising
from U0's per-spec applied-share (collapse wins without the escape tax).

**Layer 4 (the segfault's root cause — standalone freshener bug,
FIXED unconditionally, gate 1614/1614)**: `freshenLetBoundNames` renamed
MonoDef/MonoTailDef binders in inlined bodies but passed `MonoDestruct`
BINDERS through verbatim. Raised `andThen`'s body (`let (s1, a) = ma s0`)
inlines raw into thousands of callers; where a caller had its own `a`
used after the inlined segment (`constrainTupleWithIds`' param `a`), the
reference captured — gdb showed `constrainWithIds` receiving a Variable
where a Can.Expr belonged. Pins: `RaiseProbe.elm` probe2 (212 → 512) and
`DestructCaptureTest.elm` (flag-off shapes print correctly — the closure
boundary shields today's flag-off inlinable bodies, so the hole was
latent-but-unreached flag-off).

### H6.2 single-alloc follow-up (2026-07-15/16)

Shipped (all default-path gates green, final suite 1615/1615): (a) the
raiser no longer raises param-callee combinators (`apR x f = f x` —
raising them wrapped an extra PAP layer around every escaping pipe);
(b) P2 fuses GENERIC extend chains (pin:
`pap_simplify_generic_chain_fusion.mlir`; the runtime's multi-arg
generic apply chains through mid-saturation, making fusion sound);
(c) `eco_pap_extend` now CONVERTS args to the slot's declared kind (the
documented Phase-D contract) instead of storing caller encodings raw
under an OR-merged bitmap — a latent GC/read split in both directions;
the GenericApplyBoxing unit tests now declare slot kinds at create like
real typed wrappers.

Flag-on census (single PASSING run — see caveat):
creates=260,993,782 extends=218,545,991 → 479.5M events = **−12% vs
flag-off (545.4M)** and vs the pre-round flag-on 661.8M (+21%): the
extends tax dropped 400.3M → 218.5M.

**OPEN — flag-on stability**: the apR-exclusion round introduced a
nondeterministic compiler-scale crash (flake matrix: h62on2 3/3 stable;
h62on3 ~2-3/3 crash; fusion-disabled relower still crashes → fusion
exonerated; the pap_extend fix looked 4/4 stable once, then 3/3 crash on
an identical rebuild → luck, not fix). The trigger is the extra
inline/hoist/beta collapsing the exclusion unblocks (flag-on-only code
path; flag-off unaffected). ECO_ARITY_RAISE stays default-off; next
session: front-end shape audit of the newly-collapsed IR (GC root hints
across the layer-3 split residuals are the prime suspect).

### H6.2 flag-on stability — root-caused and FIXED (2026-07-15)

The "OPEN — flag-on stability" crash above is resolved. It was TWO distinct GC
use-after-frees, both latent, both exposed by ECO_ARITY_RAISE, and NEITHER in the
front end (the "newly-collapsed IR" suspicion above was wrong):

1. `Elm_Kernel_JsArray_initialize_Int` (elm-kernel-cpp) decoded and
   `StackRootGuard`-rooted its by-value `closure` AFTER `allocArrayBuilder` (a GC
   point), so the kernel's private copy went stale across a minor GC. Fixed by
   rooting before the alloc, matching the boxed `Elm_Kernel_JsArray_initialize`.
   Reproduces deterministically under `ECO_HEAP_VALIDATE`; post-fix that binary
   is `aborts=0` through the module-compile phase.
2. `eco_intern_closure0` (runtime, the H4.2 interning) allocates a permanent
   zero-capture singleton with `max_values == arity` value slots but never writes
   them, and `allocatePermanent` does not zero the old-gen body. The `Tag_Closure`
   scan (`OldGenSpace::markChildren` / `NurserySpace::scanObject`) iterates all
   `max_values` slots, so major GC followed uninitialized garbage as boxed
   HPointers. Deterministic (permanent singleton). Root-caused by static analysis
   of the post-RS4GC IR (`eco_intern_closure0` is the sole construction site,
   `packed=192` → `n_values=0/max_values=3/unboxed=0`) plus core forensics: the
   corrupt object was the interned `Terminal_Main_lambda_30517` closure, whose
   capture[2] was a use-after-free into a reused `Bytes.Decode.Decoder` type
   string. Fixed by `memset`-ing the arity value slots to 0.

STABLE flag-on census (both fixes in, native eco compiling the full compiler,
4/4 runs `rc=0`, byte-identical `.mlir` across runs):

| native eco, full-compiler compile | creates | extends | total events |
|---|---|---|---|
| flag-off (F1+F2+F3) | 405,020,772 | 140,416,526 | 545.4M |
| **flag-on (U2b), fixed** | **252,036,780 (−37.8%)** | **218,371,581 (+55.5%)** | **470.4M (−13.7%)** |

Pre-fix this workload crashed ~75% (3/4) in `OldGenSpace::markHPointer` during
major GC (heap-validate could not pin it — too slow to reach the crash, and the
stale value is a valid old-gen address the nursery tripwire cannot catch; static
IR + core forensics did). The `-13.7%` supersedes the single-run `-12%` above.
The crash is no longer a blocker; the enable decision still rests on wall-clock
(events are down but extends are still +55.5%). A parallel sweep of all
runtime/kernel C++ for the same unrooted-across-GC class found 28 latent
candidates (`kernel-gc-root-audit.md`) — separate, kernel-side, none the cause of
this crash.

**H6.3 V0 verdict**: post-F1/F2, generic-dispatch extend traffic is
140M/544M events (~26%) but is now dominated by variable-HOF-arg
partials — the class LSS stamp-coverage (V1/V2) addresses. Defer V1/V2
until after an H6.2 that works, since raising would delete many of the
same sites.

## Known measurement gotchas

- The E2E harness compile cache is mtime-only and env/config-blind
  (`test/ElmE2ETestBase.hpp` `needsRecompile`): touch all test `.elm` before
  any corpus run whose compiler/flags changed.
- The harness swallows compiler-census stderr; run `ECO_INLINE_REPORT=1`
  compiles manually (`node compiler/bin/index.js make <file> --output=… --text-mlir`).
- JIT test runs link the runtime in-process: `ECO_CLOSURE_STATS=1` on the test
  binary yields one aggregate dump at exit (all tests summed), and fps can't
  be symbolized via `nm` for JIT'd code — use AOT binaries for per-site tables.
