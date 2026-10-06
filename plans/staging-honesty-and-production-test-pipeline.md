# Staging honesty, production test pipeline, and a generic-call census

Status: **P0–P3 DONE, P4 reported** (2026-10-06); gates in §4. Background: `/work/gopt003-issue.md` (its §2.1 "majority vote"
reading and §3.4 open question are superseded by §1 below).

## 0. Goals

1. **Tests compile the way production compiles.** Every elm-test that builds a program goes through
   the same pass sequence, engine and configuration as `eco make`, through shared code that cannot
   drift. Non-production runners survive only where a test needs one, under a name that says so.
2. **GOPT_003 tells the truth**, is checked against the production pipeline, and its dead enforcer
   code is deleted. No call is annotated with a staging that is not known to be true.
3. **Measure, then remove, the staging solver.** The union-find solver and the wrapping rewriter
   inserted zero wrappers in the self-compile. If the census confirms that across the corpora,
   replace them with the GOPT_001 regrouping they actually perform.
4. **Census the generic calls** (`segmentation_unknown` / `generic_apply`). They carry about 42 % of
   all dynamic dispatches (`benchmarks/call-stats.md` group 3, `gen`). Find out why each site is
   generic and what fixing it would be worth. This plan measures and reports; it builds no transform.

Non-goals: changing the staging that codegen uses at known call sites; any new optimization.

## 1. Findings this plan rests on (verified 2026-10-06)

- **F1 — the enforcer GOPT_003 names is dead code.** `rewriteExprForAbi`, `rewriteDefForAbi`,
  `rewriteCaseForAbi`, `rewriteIfForAbi`, `processBranchResult`, `processDeciderForAbi`,
  `processJumpsForAbi`, `collectCaseLeafFunctionsGO`, `computeBranchNormalization`,
  `buildAbiWrapperGO` and `buildNestedCallsGO` (`MonoGlobalOptimize.elm` ~223-1040) only call each
  other. `ensureCallableForNode`, `makeAliasClosureGO` and `makeGeneralClosureGO` are live (they serve
  `wrapTopLevelCallables`).
- **F2 — the staging graph is almost empty.**
  - `GraphBuilder` and `ProducerInfo` never look into a `MonoCase` decider. Closures in its `Inline`
    leaves, which is nearly every branch, are not producers, so they are never wrapped.
  - `BuildCtx.varBindings` is never written.
  - The only union is `connectBranchProducer` (`GraphBuilder.elm:442`). It targets if-results,
    case-jump results, captures and record/tuple/list slots. Record/tuple/list slots are keyed
    program-wide by shape.
  - `SlotParam` nodes are created but never unioned.
- **F3 — measured: zero staging wrappers.** The self-compile output (`eco-optP3d-r1-out.mlir`) has no
  `@GlobalOpt_lambda_*` function among 57,536 functions. Wrappers get the home `eco/internal
  GlobalOpt` (`Rewriter.wrapperHome`), which prints as `GlobalOpt_lambda_<n>`.
- **F4 — `dynamicSlots` has a closed form.** `isDynamicCallee` (`MonoGlobalOptimize.elm:1881`)
  consults only `paramSlotKeys`, which are `"P:<nodeId>:<i>"` for the function-typed parameters of a
  `MonoTailFunc`. Those are `SlotParam` keys, every `SlotParam` is a producer-less singleton class
  (F2), and so all of them are dynamic. So: *a callee is dynamic iff it is a `MonoVarLocal` naming a
  function-typed parameter of the enclosing `MonoTailFunc`.*
- **F5 — one place derives a join's staging from its first branch.** `closureBodyStageArities`
  (`MonoGlobalOptimize.elm:1733`) reads the first case jump or `Inline` leaf, or the first `if`
  branch, assuming all branches agree after canonicalization. They do not (F2). So
  `remainingStageArities` can describe only branch 0. Codegen survives this because it emits the
  batch after a call result as `segmentation_unknown`, but the `CallInfo` is wrong.
- **F6 — the test harness is not the production pipeline** (`tests/TestLogic/TestPipeline.elm`).
  Production is `Builder/Generate.elm:715-1260` plus `Generate/MLIR/Backend.elm:164`. The harness:
  - defaults to the **subst** engine (`runToMono`/`runToGlobalOpt`/`runToMlir`: 37/15/91 test files),
    while the production default is **solver+LSS** (`Config.elm:542`);
  - runs **no pre-mono passes** (alias forwarding, η-expansion to declared arity — both default-on);
  - runs **no post-inline prune** (`inline.pruneDead`, default-on);
  - calls `MonoGlobalOptimize.globalOptimize` with `Config.default` arguments, but not the CSE /
    CafDedupe / CafHoist steps (all default-off today, so this is equivalent only by accident);
  - generates MLIR with `Backend.generateMlirModule`. Its context lacks `withEcoConfig`,
    ctor/null-cons/const-ctor/const-thunk tables, sret/psplit promotion, oracle facts and map
    templates, and it skips the per-node context reset. **Every `runToMlir` test checks MLIR that
    production never emits.**

  Production has **two** pipelines: the default (solver+LSS) and bootstrap Stage 5
  (`ECO_MONO_ENGINE=subst`, `compiler/CMakeLists.txt:425-432`).
- **F7 — the GOPT_003 pins fail only because of F6.** Under production, η-expansion turns
  majority2Flat's `caseFunc` into `@Stg_caseFunc_$_1(i64, i64, i64)`, and the branch lambdas
  disappear. The `if` example (`chooser`) gets the same treatment.
- **F8 — LSS interaction.** Regrouping copies the head annotation onto every stage arrow (the
  rebuilder rule; OQ4: partial applications keep the callee's member). Wrapper stages carry
  `srcLambda` (LSS_008), which makes AbiCloning decline `singleton_fast` for that member (LSS_009).
  With zero wrappers, staging costs LSS nothing today. Making it wrap more would cost singleton
  dispatch.
- **F9 — two report defects to triage first.**
  - `ECO_MONO_LSS_REPORT=1` segfaults the bootstrap Stage-6 `bin/eco-compiler` after "Success!".
    The self-compiled `eco-optP3d` does not.
  - `eco-optP3d` prints the mono census but **not** the `lss globalopt:` line
    (`Builder/Generate.elm:1977`), so `wrappersInserted` is unreadable today.

## 2. Phases

Order: **P0 → P1 → P2 → P3**, with P4 reported after P0. Each phase ends with the gate in §3 and a
commit. Temporary files go under `/tmp` only.

### P0 — Measure (no behaviour change)

**0.1 Report defects (F9).**
- Find why the `lss globalopt:` line is not printed. Read `globalOptReportStep`'s
  `if lssReport` path and the value it is passed (`ecoConfig.mono.lss.report`). Fix it if it is a
  plumbing bug; the census below needs it.
- Reproduce the Stage-6 segfault:
  ```
  cd <scratch Elm project>
  ECO_MONO_LSS_REPORT=1 /work/build/compiler/build-kernel/bin/eco-compiler make src/Stg.elm
  ```
  Then check the IntOverflow hypothesis: Stage 5 is JS-hosted, and the bytecode `VarInt` is exact
  only to 2^53. Grep the report path for Int literals above 2^53 (FNV/hash constants).
- If the hypothesis is confirmed, open a separate fix (make `VarInt` / the JS literal path reject
  or handle literals above 2^53). Do not fix it inside this plan.

**0.2 Staging census.** Add counters to `Staging.analyzeAndSolveStaging`. They are returned
alongside `wrappersInserted` and printed on the `lss globalopt:` line as `staging(...)`:
- `classes`, `classesMultiProducer` (two or more producers), `classesDisagree` (two or more
  distinct natural segmentations), `wrappers`;
- wrappers by the slot kind that unified them: `if`, `caseJump`, `capture`, `record`, `tuple`, `list`;
- `inlineLeafClosures`: function-typed closures sitting in decider `Inline` leaves, which staging
  never sees (F2);
- `dynamicParams`: the size of `dynamicSlots`, plus an assertion that it equals F4's closed form
  (crash on mismatch under `ECO_MONO_VALIDATE=1`).

Run it on three corpora:
1. **Self-compile** (fe-opt procedure, `eco-optP3d`-class binary, solver+LSS).
2. **The E2E corpus.** Add a script `test/scripts/staging-census.sh` that compiles every
   `test/*/src/*Test.elm` with the native compiler under the census flag and sums the counters.
3. **The elm-test SourceIR suites.** Add a temporary `Debug.log` test under
   `TestPipeline.runToGlobalOpt`, removed after reading.

Record the numbers in §4.

**0.3 Generic-call census (static).** In `computeCallInfo` (`MonoGlobalOptimize.elm:2013`), for
every StageCurried call whose `callKind` is `CallSegmentationUnknown` or `CallGenericApply`,
classify the callee by the first matching reason:

| tag | reason |
|---|---|
| `param` | `MonoVarLocal` naming a parameter of the enclosing function (F4's dynamic set, and the non-tail case) |
| `letUnknown` | `MonoVarLocal` bound by a `let` whose RHS has no `sourceArityForExpr` |
| `callResult` | `MonoCall` (a call result applied again: over-application past known stages, `hasUnknownExcessArgs`) |
| `field` | `MonoRecordAccess` / destructured container element |
| `join` | `MonoCase` / `MonoIf` |
| `thunkGlobal` | `MonoVarGlobal` of a non-closure `MonoDefine` (CAF/thunk) |
| `polyReturn` | `calleeHasPolymorphicReturn` (generic for an ABI reason, not a staging reason) |
| `other` | anything else |

Count sites per (tag × callKind). Print them on the same census line as `gencall(...)`.
`emptyCallEnv` already threads the per-function environment; the classifier is a pure function of
`(env, func)`.

**0.4 Generic-call census (dynamic).** Weight the static tags by execution count, following the
`ECO_LSS_DISPATCH_SITE_COUNTERS` pattern:
- **Compiler:** under the census flag, give every `segmentation_unknown`/`generic_apply`
  `eco.papExtend`/`eco.call` the attribute `_gencall_reason = <tag index>`. The attribute is
  inert otherwise; the verifier ignores `_`-prefixed attributes.
- **Lowering:** under a new `ECO_GENCALL_COUNTERS=1`, `EcoToLLVMClosures.cpp` emits
  `eco_gencall_stats(i32 reason)` before the apply when the attribute is present. Copy
  `eco_dispatch_stats_fast`'s declaration (GC-leaf).
- **Runtime:** a fixed 16-slot atomic array in `RuntimeExports.cpp`, dumped at exit as
  `[gencall-stats] param=… letUnknown=… …` when `ECO_DISPATCH_STATS=1`.
- **Run:** one census-lowered self-compile, per the `benchmarks/call-stats.md` protocol (benchmark
  arm only). Also `perf record` one plain self-compile and take the self-time share of
  `eco_apply_closure_eval` + `eco_apply_segmentation_unknown` + the PAP-extend funnel. That share is
  the ceiling of what gen→typed conversion could save. LSS `fast` conversion is a separate, larger
  prize, already tracked in `call-stats.md`.

**0.5 Report.** Write the P0 numbers into §4 and add a row to `benchmarks/call-stats.md`.

### P1 — Tests compile through the production pipeline (F6)

**1.1 Shared step functions.** Create `compiler/src/Compiler/Pipeline/Steps.elm` (pure). Move the
production logic out of `Builder/Generate.elm` into it **verbatim**:
- `prepare : EcoConfig -> TOpt.GlobalGraph -> EntryPrep.Assigned`
  — `EntryPrep.assign (assignFlagsFor cfg) "main"`.
- `preMono : EcoConfig -> Assigned -> ( Assigned, PreMonoMetrics )`
  — aliasForward → etaExpand → pre-mono inliner, each behind its existing flag, then
  `validateMinted` as a `Result`.
- `monomorphize : EcoConfig -> GlobalTypeEnv -> Assigned -> Result String ( MonoGraph, Maybe String )`
  — `selectMonomorphizer` + `ValidateLimits.check` + the `mono.validate` layout check.
- `inline : EcoConfig -> MonoGraph -> ( MonoGraph, MonoInlineSimplify.Metrics )`
  — the blacklist computation, the `inline.postMono` switch and `Prune.pruneAfterInline` under
  `pruneDead`.
- `globalOpt : EcoConfig -> MonoGraph -> ( MonoGraph, GlobalOptCarry )`
  — `globalOptimizeWithStats` → CSE → CafDedupe → CafHoist, exactly the `globalOpt*Step` bodies
  minus their stderr writes.

`Builder/Generate.elm` keeps every `Task` step and FEStats phase but calls these functions. Each
step stays its own top-level function, so the heap-release structure (plans/frontend-heap-release.md
§7) is unchanged. Reports keep reading the returned metrics.

In `Generate/MLIR/Backend.elm`, add `buildContext : EcoConfig -> Mode -> MonoGraph -> Ctx.Context`
(the `streamMlirToWriter` let-block) and a shared per-node `resetNodeCtx`. `generateMlirModule`
gains an `EcoConfig` argument and uses both, and both streamers use them.

**1.2 Harness on the shared steps.** In `TestPipeline.elm`, the canonical runners become:
- `runToMono`, `runToGlobalOpt`, `runToMlir`: `Config.default` (solver+LSS), `prepare` → `preMono` →
  `monomorphize` → `inline` → `globalOpt` → `generateMlirModule Config.default (Mode.Dev Nothing)`.
  This is the default `eco make` pipeline.
- `runToMonoStage5`, `runToGlobalOptStage5`, `runToMlirStage5`: the same with
  `mono.engine = EngineSubst`. This is the bootstrap Stage 5 pipeline.
- `runToGlobalOptLssOn` and its two aliases: delete them, and send callers to `runToGlobalOpt`.
- `runToMonoNoPreMono` (and `…GlobalOpt…`/`…Mlir…` only if a test needs one): skips `preMono`. Its
  doc says why a test may use it: to test a pass's behaviour on input that production's pre-mono
  passes would have rewritten. Each caller carries a one-line comment with its reason.
- `runToAssigned`: `prepare` with the production flags. `runSolverMonoWithLimits`/`WithReport` and
  `runSubstMonoWithLimits` stay (engine watchdog tests), now built on `prepare`/`monomorphize`.

**1.3 Drift guard.** Add `test/scripts/check-test-pipeline-production.sh`, wired as the first step
of the `elm-tests` CMake target. It fails if `TestPipeline.elm` imports any of
`Compiler.GlobalOpt.MonoInlineSimplify`, `Compiler.GlobalOpt.MonoGlobalOptimize`,
`Compiler.MonoSolver.Monomorphize`, `Compiler.Monomorphize.Monomorphize`,
`Compiler.GlobalOpt.PreMono.*` or `Compiler.GlobalOpt.Prune`. Only `Compiler.Pipeline.Steps` may run
passes.

**1.4 Fallout triage.** Run elm-tests once (CLAUDE.md protocol, `/tmp/test_output.txt`) and put
each failure in exactly one class:
- **(a) expectation encoded a non-production shape** (subst-engine output, missing η/prune,
  MLIR without const thunks/sret/…): update the expectation to the production output.
- **(b) the test exercises a pass on input that production would have rewritten first**: switch
  it to `runToMonoNoPreMono`, with the comment.
- **(c) a real compiler bug** surfaced by the production pipeline: pin it (failing test plus a note
  in `compiler/recomment-bugs.txt` style) and stop for the user's decision. Do not fix it inside
  this plan.

Record the counts per class and the per-file list in §4. Also measure elm-tests wall time before and
after. Solver+LSS is slower than subst; record it, don't optimize it here.

**1.5 Docs.** Rewrite the "differences a test can observe" paragraph of `TestPipeline`'s module doc:
the only remaining difference is the mock package environment (`Basic.testIfaces`). Update
`TestLogic` READMEs and CLAUDE.md's test notes if they name the subst default.

### P2 — GOPT_003 made honest (F1, F5, F7)

**2.1 Pins on production.** After P1 the two GOPT_003 pins run under the production pipeline and are
expected to pass with no join of differently staged lambdas left. Add residual fixtures to
`tests/SourceIR/JoinpointABICases.elm` where η cannot remove the join:
- **R1** a let-bound join used locally: `let f = case x of … in f a b + f c d`.
- **R2** a join stored in a list and applied by `List.map (\g -> g 5 3)`.
- **R3** a join passed to a higher-order parameter: `apply2 (case x of …) 5 3`, where
  `apply2 g a b = g a b`.
- **R4** a join in a record field: `{ op = case x of … }`.

Check each one against the production graph and keep those whose join survives. Add the same shapes
to `test/elm/src/Gopt003CaseStagingTest.elm`, executing **every** branch with `CHECK:` on the values.

**2.2 Honest `closureBodyStageArities`.** Return `Just stages` only when **every** branch agrees:
- for a case, all jump targets **and** all decider `Inline` leaves, through `Chain`/`FanOut`;
- for an `if`, every then-branch and the else.

On disagreement return `Nothing`; `hasUnknownExcessArgs` then makes the site
`CallSegmentationUnknown`. Before the change, use 0.3's tag counter to count production sites whose
`CallInfo` would change. Expect about 0, because of η. Gate: the self-compile `out.mlir` is
byte-identical, or every diff is explained in §4.

**2.3 GOPT_003 rewritten** (`design_docs/invariants.csv`; status `tested`):

> GOPT_003: After GlobalOpt a function-valued MonoCase or MonoIf makes no staging claim beyond what
> all of its branches agree on. Its stored type may differ from a branch's staging. No CallInfo
> derives `initialRemaining` or `remainingStageArities` from a join whose branches disagree
> (`closureBodyStageArities` returns `Nothing`), so a call whose callee value can come from such a
> join is `CallSegmentationUnknown` or `CallGenericApply`, and the runtime applies it by the
> closure header. Branch values are never re-staged to agree.
> `TestLogic.Monomorphize.MonoCaseBranchResultType (expectHonestJoinStaging)` |
> `Compiler.GlobalOpt.MonoGlobalOptimize (closureBodyStageArities)`

**The checker.** Replace `expectMonoCaseBranchResultTypesAfterGlobalOpt` with
`expectHonestJoinStaging` on `runToGlobalOpt` (production). For every `MonoCall` with
`CallDirectKnownSegmentation` whose callee is a global or closure, it walks the callee body the
same way `closureBodyStageArities` does. It asserts that whenever the reached join's branches
disagree, the call claims nothing past the first stage. Keep MONO_018's pre-GlobalOpt check
unchanged. Rename the pin group from "GOPT_003 BUG PIN" to "GOPT_003".

**2.4 Delete the dead enforcer** (F1): the eleven functions listed there, and the GOPT_016
(WrapperCalls) row, which documents `buildNestedCallsGO`. invariants.csv has **two** rows with the
id GOPT_016: WrapperCalls (line 226) and CallKind (line 353). Delete the first and keep CallKind. Point CGEN_055 at the live wrappers only,
or retire it if they never stage-split. Update the docs that describe the vote as making join types
truthful:
- `design_docs/theory/staged_currying_theory.md` (§"Joinpoint Matching Algorithm", §Invariant
  GOPT_003);
- `design_docs/monomorphization/lambda-set-specialization-design.md` §9.3(a).

**2.5 `validateClosureStaging`.** Make it a real GOPT_001 check: params == `stageParamTypes` length
for every `MonoClosure`, tail function and define. Run it only under `mono.validate`
(`ECO_MONO_VALIDATE=1`) and fail the compile with a located message. Today it returns its input
unchanged.

### P3 — Replace the staging solver with plain regrouping (F2-F4)

Precondition: P0.2 shows `wrappers = 0` on the self-compile **and** the E2E corpus, and P2.2 has
landed. If the E2E corpus has wrappers, list them in §4 and proceed only if each one feeds no claim
that P2.2 left in place.

- **3.1** `Compiler.GlobalOpt.Staging` becomes `regroup : MonoGraph -> MonoGraph`: the Rewriter's
  no-class arms. Every `MonoClosure` and `MonoTailFunc` gets `flattenTypeToArity (params) type`;
  `MonoDefine` takes its rewritten expression's type. No classes and no wrapping. Keep the
  rebuilder rule: `flattenTypeToArity` copies `headAnno`.
- **3.2** Replace `dynamicSlots` by F4's closed form. `isDynamicCallee env f` = `f` is a
  `MonoVarLocal` in `env.paramSlotKeys` with a function type. `paramSlotKeys` becomes a `Set Name`,
  and the `dynamicSlots` argument of `annotateCallStaging`/`emptyCallEnv` goes away.
- **3.3** Delete `Staging/GraphBuilder.elm`, `Solver.elm`, `ProducerInfo.elm`, `UnionFind.elm`,
  `Types.elm` (move `Segmentation` to where it is still used, or use `Mono.Segmentation`), and the
  wrapper half of `Rewriter.elm` (`wrapClosureToCanonical`, `buildNestedWrapper`,
  `buildNestedCalls`).
  - `Rewriter.wrapperHome` has two readers, `AbiCloning.elm:691` and `Borrow/LssFacts.elm:252`.
    No closure has that home any more, so delete the comparisons and the constant.
  - Drop `wrappersInserted` from `GlobalOptStats` and the `lss globalopt:` line;
    `benchmarks/call-stats-extract.py` does not read it.
- **3.4** Docs and invariants:
  - LSS_008: drop the staging-wrapper clause; inliner copies still apply.
  - GOPT_001: the enforcer becomes `Staging.regroup`.
  - `staged_currying_theory.md`: rewrite the solver sections as history, one paragraph saying what
    replaced them.
  - `pass_global_optimization_theory.md` phase list.
  - THEORY.md if it names the solver.
- **3.5** Measure the GlobalOpt phase time on the self-compile (`--stats` FEStats `PhaseGlobalOpt`,
  N=3 medians) before and after, and record it in §4.

### P4 — Generic-call opportunity: decision only

From 0.3/0.4, write in §4:
- the dispatch weight per reason tag;
- the funnel's share of wall time (0.4's perf);
- for each tag, the analysis that could convert it, with an estimate:

| tag | candidate analysis |
|---|---|
| `param` | interprocedural: every call site of the function passes a closure of known staging |
| `letUnknown` | intraprocedural flow |
| `callResult` | return-staging summaries |
| `field` | per-field-key flow, which is what the old record slots tried to do program-wide |
| `join` | all-branches-agree, already done by P2.2 |

Recommend one follow-up plan, or none if the convertible weight × the funnel premium is under
~1 % of wall. LSS `fast` stamping, which removes the indirect call altogether, is the competing use
of the same effort. Compare against it explicitly.

## 3. Gates (per phase)

Every phase:
- elm-tests: only the known pins fail. After P2 the GOPT_003 pins pass, so the expected failure
  count is **0**.
- `full` after the cache wipe (`build/test/*/eco-stuff`, `~/.eco/0.1.3` `*artifacts.dat`,
  `packages/eco/kernel`).
- `run-aot-e2e`: 932 + 2 skipped.
- `run-mlir-equivalence`.
- bootstrap + `eco-verify` (Stage 8c fixed point).

Self-compile `out.mlir`:
- P0 (counters only): byte-identical.
- P1: **byte-identical**. `Steps` is a verbatim move; any diff is a P1 bug.
- P2.2: byte-identical, or diffs explained.
- P3: byte-identical **if** the self-compile had 0 wrappers.

Perf triple (fe-opt procedure, N=3 medians, same-source arms) after P1 and P3: wall within noise
(1.3 %) or better. P3 is expected to be slightly better.

Validate tree (`build-validate`) only after P3 (GlobalOpt change): unit plus E2E.

## 4. Results

*(filled in as phases complete)*

| item | value |
|---|---|
| P0.1 globalopt line | **Not a defect.** The line prints; the earlier `grep` treated the log as binary (it holds NUL bytes). Use `grep -a`. |
| P0.1 Stage-6 report segfault | **Substitution-engine miscompile, not the JS literal.** A compiler built natively with `ECO_MONO_ENGINE=subst` (eco-optP3d → `/tmp/eco-subst-native`) crashes identically: SIGSEGV in `Terminal_Main_lambda_*$cap` under `vf3ExprClosures` in `MonoSolver.Monomorphize.renderLssReport` (an `Array.foldl` over the nodes). Solver-built compilers do not crash there. Not fixed here (out of scope); repro: `ECO_MONO_LSS_REPORT=1 <subst-built compiler> make src/Stg.elm` in any project. |
| P0.1 found on the way: shadow-root overflow | **Runtime GC-rooting defect.** `ECO_MONO_LSS_REPORT=1` and `ECO_MONO_LSS_CENSUS=1` both abort the self-compile on every current binary (eco-optP3d included): `FATAL: GC shadow root stack overflow at depth 65536`. Backtrace: `Elm::alloc::listFromUnboxables` pushes one root range PER boxed element (`HeapHelpers.hpp`), reached from `Elm_Kernel_List_sortBy` (`listFromPermutation`) on a 142,895-element list inside `renderLssReport`. `ListOps.cpp` `map`/`indexedMap`/`filter`/`filterMap` root their accumulators the same way. The check runs only under `!NDEBUG`/`ECO_HEAP_VALIDATE`; an `NDEBUG` build would write past the stack's slack instead. Any Elm list over 65,536 boxed elements through these kernels is affected. Not fixed here: a GC-rooting change for its own plan. **E2E pins:** the 12 `RootStack*Test` programs listed in plans/kernel-root-stack-bounded-rooting.md §1.3 abort with the FATAL today. Consequence for this plan: the `call-stats.md` protocol (`ECO_MONO_LSS_REPORT=1`) is currently unusable on the self-compile, so the staging census got its own flag, `ECO_STAGING_REPORT=1` (`mono.stagingReport`). |
| P0.2 self-compile: classes / multi / disagree / wrappers / inlineLeafClosures | (eco-optG2, solver+LSS, `ECO_STAGING_REPORT=1`) classes **38,624**, multiProducer 4, **disagree 0, wrappers 0**, inlineLeafClosures 0, inlineLeafDisagree 0, dynamicParams 9,636, **paramClosedFormMisses 0**. |
| P0.2 E2E corpus: same | (`test/scripts/staging-census.sh`, eco-optG2, 936 programs, 0 failed) classes 8,412, multiProducer 3, **disagree 0, wrappers 0**, inlineLeafClosures 14, **inlineLeafDisagree 6** (the GOPT\_003 shape survives η in real programs), dynamicParams 1,473, paramClosedFormMisses 0. gencall static: segunk param 2,797 / local 866 / callResult 31 / field 13 / global 6 / other 3; generic param 379 / local 1. |
| P0.2 SourceIR suites: same | 1,124 programs under the old harness (`runToMono` subst + inliner + `globalOptimizeWithStats`): classes 953, multiProducer 6, **disagree 0, wrappers 0**, inlineLeafClosures 50, **inlineLeafDisagree 11** (the GOPT_003 shape staging never sees), dynamicParams 48, **paramClosedFormMisses 0**. gencall static: segunk param 98 / local 49 / callResult 21 / global 8 / field 5 / join 2 / other 1; generic local 9 / param 2. |
| P0.3 static gen sites by tag × kind | self-compile: segunk **param 12,549**, **local 8,081**, field 830, global 85, callResult 20, join 20, other 10; generic param 1,827 (= the tail-function-parameter rule). |
| P0.4 dynamic gen dispatches by tag; funnel % of wall | census-lowered eco-optG2c self-compile (`ECO_GENCALL_COUNTERS=1 ECO_LSS_DISPATCH_SITE_COUNTERS=1`, run `ECO_DISPATCH_STATS=1 ECO_STAGING_REPORT=1`): `[dispatch-stats] sat=74.9M gen=64.4M typed=10.5M fast=377.0M`. Generic papExtend executions by codegen reason (`[gencall-stats]`, saturating and PAP-building alike): local-variable callee **201.2M**, join 16.9M (from 20 static sites), rest of a stamped over-applied call 14.5M, call result 5.3M, field 3.4M, global 1.1M, other 8.8K; no untagged op. `perf` (plain eco-optG2 self-compile, 435K samples): `eco_apply_closure_eval` 0.85 % + `invokeSaturatedTyped` 0.74 % + `eco_pap_extend_l` 0.22 % self time, against 0.42 % for the typed path (`eco_closure_call_saturated{,_eval}`). |
| P1.4 fallout (a) / (b) / (c); elm-tests wall before/after | First production run: 89 failures. **The dominant cause was the harness, not the pipeline:** the synthetic `main` bound `testValue` to an unused `let`; the inliner dropped it and the post-inline prune then removed `testValue` and all it reached (~45 failures, and the 17-minute run). `main` now uses it (`Html.text (Elm.Kernel.Debug.toString testValue)`). Then: **(a) 13** — MONO\_006/007/018 checkers compared types with `==` (lambda-set annotations are per occurrence under the solver, ⊤ carries a provenance code) → `Mono.eqLayout`; MONO\_017 compares variables by constraint; `UnboxedBitmap` accepts the copies constant-thunk folding emits; two inliner let-elimination fixtures had a USED binding (they passed only because of the old `main`'s dead `let`). **(b) 13** — eight LSS analysis test files pinning rules on hand-written shapes that alias forwarding / η rewrite → `NoPreMono` runners with a reason comment; three subst-engine-intent tests and `withSubstMetrics` → `runToMonoStage5`. **(c) 4 real bugs, pinned (5 failing tests):** C1 MONO\_017: the solver registers a constructor spec at its function type (`Int -> Box`) while the node holds `Box`; C2 MONO\_011: a let-bound polymorphic tail-recursive function at two types — the solver's second specialization names `foldl$1` / `reverseHelper$1` out of scope, and **`eco make` crashes** ("lookupVar: unbound variable foldl$1"; E2E pin `test/elm/src/PolyLetTailRecTwoTypesTest.elm`); C3 MONO\_006: in a record update of a let-bound polymorphic record the solver leaves `MVar CEcoValue -> Int` on the record where the update has `Int -> Int` ("Edge case…" and "Polymorphic TVar escape… has complete layouts"); C4 REP\_BOUNDARY\_003: the erased-list specialization of `count` recurses into the `List Int` specialization (boxed elements into an unboxed-element callee; harmless at run time while an erased list is necessarily empty). elm-tests wall: ~40 s before, 52 s after. Open question (MONO\_017): should a registry key's lambda-set annotation have to equal its node type's (seen: key `LSet [2]`, node `LTop 18`)? The check now compares layouts. |
| P2.2 production CallInfo sites changed | **0 in the self-compile**: compiling the same source with eco-optG3 (before P2/P3) and eco-optG5 (after) gives byte-identical output (`P2+P3 BYTE-IDENTICAL`, G5 at a fixed point). JoinpointABI category 6 (6.1–6.4) keeps one function-typed join each in the production graph; categories 1–5 keep none (η dissolves them). |
| P3.5 GlobalOpt phase time before/after | Perf triple (fe-opt procedure, N=3, same source, all three arms emit byte-identical output): eco-optG2 (before P1) wall median **69.64 s**, GlobalOpt 1.4 s, RSS 6.381 GB; eco-optG3 (after P1) **68.32 s**, 1.4 s, 6.378 GB; eco-optG5 (after P2+P3) **68.31 s**, GlobalOpt **1.1 s** (−0.3 s), RSS **6.338 GB** (−42 MB). P1 and P3 are both flat-or-better on wall. |
| Gates (after P3) | elm-tests 14,098 / 5 fail = the four pinned bugs (§P1.4 (c)); `full` 2,128 / 1 fail, AOT 932 / 1 fail + 2 skipped, MLIR equivalence 946 / 1 fail, validate tree 2,129 / 1 fail — each the E2E pin `PolyLetTailRecTwoTypesTest` (bug C2); bootstrap Stage 8c fixed point + `eco-verify` pass; strict TLA canary pass (M1 audited for the census counter). Self-compile byte-identical across P1 and across P2+P3. |
| P4 recommendation | **No staging flow analysis.** The whole generic-call path is ~1.8 % of self-compile cycles in self time (`eco_apply_closure_eval` + `invokeSaturatedTyped` + `eco_pap_extend_l`), and converting a generic call to a typed one keeps the indirect call, so the convertible premium is well under 1 % of wall: below the plan's bar for every tag that needs real flow analysis — `param` (14.4K static sites, the bulk of the 201M local-variable executions; interprocedural) and `local` (8.1K; intraprocedural). For those, LSS fast stamping is the better lever (it removes the indirect call; `fast` = 377M already): extend stamping, not staging. **One cheap candidate is worth a small follow-up plan:** the 20 static `join` sites carry 16.9M generic executions — a call whose callee is itself a `case`/`if` of lambdas. Distributing the application into the branches (`(case x of A -> \a -> e1; …) y` ⇒ `case x of A -> e1[y/a]; …`) makes each a beta-reduction, i.e. no call at all; it is syntactic, local, and measurable on `[gencall-stats] r4`. |
