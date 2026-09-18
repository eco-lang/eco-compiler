# Remove the seven default-OFF LSS flags and the code they gate

**Status: PLANNED 2026-09-17.** Scope: delete seven `LssConfig` knobs that ship
default-off, together with every branch they gate, their env handlers, decoder
fields, hash tokens and tests. No behaviour change is intended at defaults — the
gate is byte-identical output.

## §1 WHY

Each of the seven is off for a recorded reason, and none of the reasons is
"not measured yet" (evidence gathered 2026-09-17, cited per flag in §2). Three
were measured and refused (`argPoints`, `qSolve`, `flow.rowDefer`), two are
superseded by shipped mechanisms (`spineArity` by `papMembers`/`refPapSpine`,
`sigRootIdentity` by `arrowSolverRoots`), and one pair was never implemented at
all (`stageAnchor.*`). Carrying them costs:

- **Dead branches on hot paths.** `argPoints` puts a flag test in `walkExpr`'s
  `Call` arm and in `joinLetUse`; `sigRootIdentity` puts one in the memo key of
  `Store.loadTypeC`, the single hottest function in the solver.
- **A soundness trap.** `sigRootIdentity` REQUIRES `papMembers`; the two
  together off-by-one is the recorded `Task.map f` → identity-map miscompile.
  Deleting it deletes the trap.
- **Record-slot pressure.** `LssConfig` is AT the runtime's 32-slot GC-scan cap
  (`eco.construct.record` rejects a 33rd field), which is why every flag since
  2026-09 had to go in a sub-record. Removing four top-level fields plus the
  `stageAnchor` sub-record frees five slots.
- **Benchmark noise.** The flag-off loop (`benchmarks/flag-off-lss-loop.md`)
  must skip every one of them, and each skip costs the protocol its only
  same-config repeat.

## §2 WHAT — the seven, and the evidence that retires each

| Flag | Field | Evidence |
|---|---|---|
| `spineArity` | `LssConfig.spineArity` | `plans/list-map-mlir-template.md:998` — F-5C landed default-off, "0 (measured no-op at any depth)". `plans/lss-ref-pap-spine.md:85-93,167-171` — now CONFLICTS with the shipped `papMembers`/`refPapSpine`: it would name a global and its PAP with one `g\|X` id, and AR-5 marks it "dormant and slated for retirement if this ships". It shipped. |
| `qSolve` | `LssConfig.qSolve` | `plans/lss-paper-inclusion-constraints.md:790-815` — §5.2 BUILT and "MEASURED byte-identical flag-off vs flag-on across all eight probes"; "buys no precision on its own and is not claimed to". Its only purpose was to precede §5.3, which §5.6.3:990-1014 then declined to build (`divergeSuper=0`, `union=24` of 233,751). Successor `plans/lss-promote-quantified-set-variables.md` is a NO-GO. |
| `sigRootIdentity` | `LssConfig.sigRootIdentity` | Default-ON 2026-08-27 → 2026-09-16, then off: with `arrowSolverRoots` on, `AssignMVarIds` already gives every solver-root slot one shared arrow id, so call-stats Run 27 measured **emission byte-identical with it off**. `plans/lss-root-fold-depth-qualified-spine.md:8-13` — the two are mutually exclusive by construction. |
| `argPoints` | `LssConfig.argPoints` | `plans/lss-coverage-four-levers.md:400-430` micro-gate FAILED; §7.5:490 self-compile **coverage −0.21 pp, var +332**, "NO-GO for a default flip". Re-measured in `plans/lss-ctor-arrow-identity.md:642-664` on top of `argFeedback`: **byte-identical census, coverage 89.39 % both arms** — "measured-inert rather than measured-harmful". |
| `stageAnchor.rowFill` | `LssStageAnchorConfig.rowFill` | `plans/lss-stage-anchor-writers.md` reaches ORDER 1; **ORDER 2 (W2 rowFill) was never executed**. Verified: `grep stageAnchor compiler/src/` hits only the two `Eco/Config.elm` files — no consumer exists. |
| `stageAnchor.demandFill` | `LssStageAnchorConfig.demandFill` | Same plan, **ORDER 3 (W1 demandFill) never executed**; same grep. |
| `flow.rowDefer` | `LssFlowConfig.rowDefer` | `plans/lss-container-payload-transport.md:1490-1528` — F3-a complete and sound, and the same-run A/B is `var` 893 both arms, `coveredBp` 9892 = 9892, `devirtDirect`/`devirtKernel` identical: "It buys nothing today… the positions it could uniquely recover are gated behind roots it does not own." |

**What is NOT in scope.** The censuses (`report`, `qCensus`, `arrowCensus`,
`stamp.census`) stay — they are output-only verifiers, and `qCensus` in
particular is the standing LSS_037 guard. The two numeric caps (`maxSetSize`,
`maxSpecsPerGlobal`) stay — `0` is "unlimited", not "off", and
`ECO_MONO_LSS_MAX_SPECS` is the documented backstop for the elm-aws-codegen
pathological-workload class.

**`declaredArityOf` is NOT part of `spineArity`.** It has 15 callers across
`Monomorphize`/`Translate`/`LssInfer` (papMembers saturation checks, root-fold
depth, `stampSpineGo`). Only `spineDepthForGlobal`, its one flag-gated wrapper,
goes.

**The `Store.qSolve` function is NOT the `qSolve` flag.** `Store.elm:1830`
is the shadow-`Q` solver behind `qCensus`. It stays.

## §3 HOW — per flag, in this order

Each step ends with the compiler type-checking. Order runs cheapest-first so a
mistake is found before the expensive edits.

### 3.1 `stageAnchor.rowFill` / `demandFill` — config-only

Delete `LssStageAnchorConfig`, the `stageAnchor` field, its decoder, its two
hash tokens, the two env handlers and their `applyEnvOverrides` links, and the
export from `Compiler.Eco.Config`. No compiler-side consumer exists.

### 3.2 `spineArity`

- Delete the field, `defaultLss` entry, decoder line, hash token, env handler.
- Delete `LssInfer.spineDepthForGlobal` and its export.
- `standaloneMemberWith`'s `depthOf` parameter is then always `\_ -> 1`: drop
  the parameter and call `injectSpineMemberId 1` directly. Five call sites
  (`LssInfer.elm:1465,1471,1513,1518,1531,1538`) lose their first argument.
- `Translate.elm:4813` becomes `injectSpineMemberId 1 mid canVar`.
- Keep `declaredArityOf` / `declaredArityGo` and their doc comments, minus the
  `spineArity`-dormancy sentences.

### 3.3 `qSolve`

- Delete the field, default, decoder, hash token, env handler.
- Delete `LssInfer.applyFacts`' `else if s0.env.lss.qSolve` branch (the
  `applyFactsGo` arm becomes the `else`).
- Delete `instantiateScheme`, `schemeTie`, `schemeFacts`, `schemeResidual`.
- `Engine.LssSignature.quantified` then has no reader: delete the field, its
  construction in `LssInfer` (~:925) and in `Engine.trivialSignature` (~:540).
  `residual` IS still read (`Monomorphize.elm:3725,3791` census) — keep it.

### 3.4 `argPoints`

Six gated sites; each keeps its existing flag-OFF arm:

| site | flag-off arm to keep |
|---|---|
| `LssInfer.elm:1411` (`walkExpr` `Call`) | the historical `walkCall` path |
| `LssInfer.elm:1485` (container-typed reference) | `Ok ( WpNone, s1 )` |
| `LssInfer.elm:2100,2107` (`VarEnum`/`VarBox` callee) | `Ok ( WpNone, s0 )` |
| `LssInfer.elm:3336` (`joinLetUse` guard) | `Ok ( WpNone, s0 )` |
| `Translate.elm:4720` | the non-access arm |

Then delete whatever becomes unreachable — candidates to verify by grep, not
by assumption: `walkArgsCollect`, `unifyParamsWithPoints`, `kernelCallBoundaryWith`,
`applyCalleeAtWith`'s point plumbing, `instantiateWithSignature`,
`sigSourceTypeFor`, and the `argpt|*` census counters. Anything still reachable
from a default-on path stays.

### 3.5 `sigRootIdentity`

- Delete the field, default, decoder, hash token, env handler.
- `AssignMVarIds`: delete `recordRootKey` and the `GlobalMVarState` fields
  `rootKeyEnv`, `nextRootKey`, `arrowRootOf`. The `TypeIds.SolverRoot` arm's
  `else` branch becomes plain `freshArrowId ctx`. **Keep `arrowRootEnv` and
  `ensureArrowIdForRoot`** — those are Phase 2b (`arrowSolverRoots`,
  default-ON).
- `Engine`: delete `Env.arrowRootOf`, `S.scratchRootKeys` and its two
  assignments (`:2168`, `:2226`).
- `Store`: delete `LoadCtx.arrowKeyRoots` / `LoadCtx.arrowRootOf`, the
  `testLoadCtxRoots` helper, and `loadTypeC`'s memo-key translation
  (`:374-375`) — the occurrence key becomes the only key.
- `Monomorphize`: the two census readouts of `Dict.size arrowRootOf`
  (`:2409`, `:4192`) go with it.
- Delete `compiler/tests/TestLogic/Monomorphize/LssSigRootIdentityTest.elm` and
  drop it from the suite list; fix the references in `TestPipeline.elm`,
  `LssPapMembersTest.elm`, `LssSigFlowTest.elm`.

### 3.6 `flow.rowDefer` — the largest, and last

- Delete the field, default, decoder, hash token, env handler.
- `Monomorphize`: delete `settleRowRefs` and its helpers (the `rowDefer|*`
  census block) and unlink it from the settle chain.
- `Translate`: delete the `LRow` mint (`:8280-8390`) and `payloadRowPrefix`.
- `Compiler.AST.Monomorphized`: delete the `LRow` constructor of
  `LambdaSetAnno` and its 42 arms — `unionAnno`, `annoCovers`, `annoCoverage`,
  rendering, hashing. Every `case` over `LambdaSetAnno` loses one branch;
  none gains a wildcard.
- Guards that decline on `LRow` (`AbiCloning`, `MapTemplate` ×3,
  `Borrow.LssFacts`, `Store`) lose their `LRow` arm.
- Delete `compiler/tests/TestLogic/Monomorphize/LssRowDeferTest.elm`; remove
  the `Mono.LRow` case arms from the ~20 test modules whose render helpers
  match on the constructor.

### 3.7 Docs and harness

- `benchmarks/flag-off-lss-loop.md` — drop the seven rows and renumber
  (41 flags → 34; the reference pair moves 42 → 35). With them gone the only
  remaining skips are the two numeric caps, so the loop becomes 33 real
  iterations out of 35 rows.
- `benchmarks/flag-off-lss-run.sh` — same edit to `SKIP`, `EFFECTIVE`,
  `off_env_for`, `flag_name_for`, `cumulative_env`.
- Add a one-line `REMOVED 2026-09-17` status note at the top of the five owning
  plans (`list-map-mlir-template.md` F-5C, `lss-paper-inclusion-constraints.md`,
  `lss-solver-root-signature-identity.md`, `lss-coverage-four-levers.md`,
  `lss-stage-anchor-writers.md`, `lss-container-payload-transport.md` F3-a).
  The plans stay as the record of what was measured; the note says the code is
  gone.
- `design_docs/invariants.csv` — check for rows naming these flags; amend only
  if a row's text is made false by the removal.

## §4 GATES

Every removed flag is default-off, so this is a pure-deletion change and the
bar is exact equality, not "no regression".

| # | Gate | Expectation |
|---|---|---|
| 1 | Default config hash | UNCHANGED — tokens only emit when non-default, so no cache invalidation |
| 2 | `cmake --build build --target full` (E2E) | at the standing pass count; run ONCE, tee to `/tmp/test_output.txt` |
| 3 | `cmake --build build --target elm-tests` | at the standing set (13,568 / standing 12), minus the two deleted modules' cases |
| 4 | **Fixed-workload `.mlir` byte-identical**, pre-change binary vs post-change binary | THE gate — if this moves, a removal was not flag-gated after all |
| 5 | `cmake --build build --target bootstrap` | Stage 4b (JS) and Stage 8c (native) fixed points both green |
| 5 | `cmake --build build --target bootstrap` | **4b and 8c both green** (§6.7) |
| 6 | `benchmarks/call-stats.md` Run 28 | **recorded** as the post-removal baseline (§6.8) |

**Gate 6 is not an equality gate, for gate 4's reason.** The call-stats workload
IS the compiler's own source, and this change deletes ~2 % of it, so positions,
`k1`, `kN` and every absolute count in groups 1–2 legitimately move — and
groups 3–4 move with them, because the binary is executing a smaller program.
Run 27's figures were also taken on the 2026-09-16 tree, before
`stamp.rootFoldDepth` shipped, so they are not a same-source arm either way.
Run 28 therefore RECORDS the post-removal baseline; the only cross-run readings
that stay meaningful are the RATIOS (analysis coverage %, fast-dispatch share,
static-target %), and even those carry a workload caveat. The correctness
question is settled by gate 4, which is an equality on workloads that did not
change.

Gate 4 needs care: the compiler's OWN self-compile output legitimately changes,
because the workload for that run is the compiler source this change edits.
So the equality is taken on workloads this change does NOT touch — a sample of
`test/elm/src/*.elm` plus `examples/src/Hello.elm` — compiled by a pre-change
binary and a post-change binary. Both binaries are emitted from their own tree
by the same seed and lowered by `eco-boot-native`, so the only difference
between them is the deleted code. It is the cheapest decisive gate; take it
before starting the bootstrap.

## §5 RISKS

- **`argPoints` helper over-deletion.** Several of its helpers have `…With`
  twins that the default path still calls (`applyCalleeAt` delegates to
  `applyCalleeAtWith`). Delete only what grep proves unreferenced.
- **`LRow` arm removal is exhaustiveness-driven**, which is the safe direction:
  the Elm compiler names every site. The hazard is the opposite — a `_ ->`
  wildcard that silently absorbs the removal. Do not add one.
- **`arrowRootEnv` vs `arrowRootOf`.** Near-identical names, opposite fates:
  `arrowRootEnv` is `arrowSolverRoots` (KEEP), `arrowRootOf` is
  `sigRootIdentity` (DELETE).
- **Positional decoders.** `lssDecoder`/`lssFlowDecoder`/`lssInstanceQualDecoder`
  apply fields in order; removing one means removing its `D.apply` line, not
  just the record field, or every later field shifts.

---

## §6 RESULTS (2026-09-17)

### 6.1 What was removed

| Flag | Config | Machinery deleted |
|---|---|---|
| `stageAnchor.rowFill` / `.demandFill` | field, sub-record `LssStageAnchorConfig`, decoder, 2 hash tokens, 2 env handlers, `updateLssStageAnchor` | none — there was never a consumer |
| `spineArity` | field, default, decoder, `lssSA=` token, env handler | `LssInfer.spineDepthForGlobal`; `standaloneMemberWith` lost its depth parameter (6 call sites); `Translate` spine write pinned to 1. `declaredArityOf` KEPT (15 unrelated callers) |
| `qSolve` | field, default, decoder, `lssQS=` token, env handler | `applyFacts`' scheme branch, `instantiateScheme`, `schemeTie`, `schemeFacts`, `schemeResidual`, and `LssSignature.quantified` (write-only once the branch went). `residual` KEPT — two census readers. `Store.qSolve`, the shadow-`Q` solver, is a different thing and KEPT |
| `argPoints` | field, default, decoder, `lssAP=` token, env handler | 6 gated branches; `walkArgsCollect`; the dead `exprTag` diagnosis helper; and the whole `…With` point plumbing collapsed — `walkCallWith`/`applyCalleeAtWith`/`kernelCallBoundaryWith`/`unifyCallShapeWith`/`unifyParamsWithPoints` merged back into their plain-`args` forms. `argpt|*` and `argleak|*` counters gone |
| `sigRootIdentity` | field, default, decoder, `lssSR=` token, env handler | `AssignMVarIds.recordRootKey` + `rootKeyEnv`/`nextRootKey`/`arrowRootOf`; `Engine.Env.arrowRootOf`, `Env.arrowRootClasses`, `S.scratchRootKeys`; `Store.LoadCtx.arrowKeyRoots`/`arrowRootOf`, `testLoadCtxRoots`, and `loadTypeC`'s memo-key translation (the memo key IS the occurrence key now); the `provenance:` report line, which could only print zeros once `arrowSolverRoots` shipped. `arrowRootEnv`/`ensureArrowIdForRoot` KEPT — those are Phase 2b |
| `flow.rowDefer` | field, default, decoder, `lssFRD=` token, env handler, `setFlowRowDefer` | `Translate.rowifyPayload`/`payloadRowPrefix`/`rowifyGo`/`rowifyList`; `Monomorphize.settleRowRefs` (~470 lines) and its settle-chain link; the `LambdaSetAnno.LRow` constructor and its 25 arms in `Monomorphized`, plus 12 arms across `AbiCloning`/`MapTemplate`/`LssFacts`/`Monomorphize`/`Translate`/`Store`; the `Vars.LsRow` store constructor and its `Unify`/`Store` arms; `rowDefer|*` counters |

Tests: `LssSigRootIdentityTest.elm` and `LssRowDeferTest.elm` deleted; `Mono.LRow`
render arms stripped from 20 test modules; the `sigRootIdentity` pins in
`LssPapMembersTest` / `LssSigFlowTest` / `TestPipeline` rewritten (the
`papMembers` co-requirement they guarded no longer exists).

Docs: `benchmarks/flag-off-lss-loop.md` + `flag-off-lss-run.sh` renumbered to
34 flags + reference, with only the two numeric caps still skipped;
`design_docs/invariants.csv` LSS_025 amended — its "with `spineArity = False`,
standalone members live on the HEAD arrow only" is now unconditional; a
`FLAG REMOVED` note added to each of the six owning plans.

`LssConfig` drops from 32 fields to 27, back off the runtime's 32-slot
GC-scan cap.

### 6.2 Gates

| # | Gate | Result |
|---|---|---|
| 1 | Default config hash | Unchanged by construction: every removed token was emitted only when non-default, and all seven shipped default-off. Subsumed by gate 4 |
| 2 | `cmake --build build --target full` (E2E) | **1,727 run / 1,727 passed / 0 failed — PASSED** (§6.6) |
| 3 | `cmake --build build --target elm-tests` | **13,556 passed / 12 failed.** The 12 are the standing pre-existing TYPE_007 failures. 13,568 → 13,556 is exactly the 12 cases in the two deleted test modules |
| 4 | Fixed-workload `.mlir` byte equality | **11/11 byte-identical** (§6.5) |

### 6.3 Source-size effect

The compiler's own emitted MLIR, same workload (`Terminal/Main.elm`), same
config, pre-change binary doing both compiles:

| tree | `out.mlir` |
|---|---:|
| pre-change | 13,751,352 B |
| post-change | 13,458,106 B |
| | **−293,246 B (−2.13 %)** |

That is the deleted code leaving the compiler's own artifact — expected, and the
reason gate 4 cannot be a self-compile equality (see §4).

### 6.4 One self-inflicted defect, found and fixed

The `LRow` arms were removed with a mechanical arm-stripper that also deletes
the comment block attached above each arm. In `Monomorphized.annoCovers` two
comment blocks were ADJACENT — the `LPartial` arms' block sat directly above the
`LRow` arms' block with no blank line between — so removing the `LRow` arms took
the `LPartial` documentation with them. That block states the **LSS_010 covers
law** ("`annoCovers` must decide exactly `unionAnno a b == a`; blanket-False
arms made the changed flag falsely True and the flush oscillate — the 100-round
watchdog caught it"), which is exactly the kind of comment that must not be
lost. Restored verbatim.

The other eleven strip sites (`LssFacts`, `AbiCloning`, `MapTemplate` ×3,
`Monomorphize` ×4, `Translate` ×3) were audited afterwards: every surviving arm
still carries its own comment, and the only removed text is the `LRow` arms'
own. Code was never at risk — the type checker and 13,556 unit tests cover that
— but comments in this codebase carry the measurements, and a silent deletion
would have been the real cost.

**Rule for the next mechanical arm removal:** a stripper that walks back over
contiguous `--` lines cannot tell two adjacent comment blocks apart. Diff the
result, or strip the arms and delete the comments by hand.

### 6.5 Gate 4 — PASSED, byte-identical

Pre-change binary (`eco-pre`, from `pre-change.mlir`) vs post-change binary
(`eco-post`, from `post-change.mlir`), each compiling the SAME eleven workloads
that this change does not edit. Artefacts in `/work/lss-flag-removal/`.

| workload | bytes | verdict |
|---|---:|---|
| `AliasForwardTest` | 9,018 | identical |
| `AndThenProbe` | 2,518 | identical |
| `CombinatorRefIdentityBugTest` | 2,104 | identical |
| `DictDiffFoldlStringKeysTest` | 18,471 | identical |
| `DictMapStagedCaptureTest` | 6,002 | identical |
| `Hello` (examples) | 8,154 | identical |
| `ListMapTest` | 3,512 | identical |
| `LssGapLambdaStages` | 1,991 | identical |
| `PapCopyStampTest` | 6,497 | identical |
| `PapStampTest` | 4,736 | identical |
| `RecordUpdateTest` | 1,099 | identical |

**11/11 byte-identical.** This is the gate that proves the deletions were
genuinely flag-gated: if any removed branch had been reachable at defaults, or
any `…With` collapse had changed a unify order, these would move. The set is
chosen for LSS density — PAP stamping, devirt, dict folds, alias forwarding,
the recorded combinator miscompile reproducer, and the lambda-stage probe that
`stageAnchor` was written for.

### 6.6 Gate 2 — E2E PASSED

`cmake --build build --target full` (clean, rebuild ALL + Stage 1, run the JIT
E2E suite), one run, `/tmp/test_output.txt`:

```
Tests run:    1727
Tests passed: 1727
Tests failed: 0
Result: PASSED
```

All 632 Elm programs plus the elm-core / elm-bytes / elm-parser / elm-json /
elm-url / elm-http / elm-time / eco-kernel suites and the codegen MLIR checks
compiled and ran clean. Zero failures — no standing set to net out here,
unlike the unit suite.

### 6.7 Gate 5 — BOOTSTRAP, both fixed points green

`cmake --build build --target bootstrap`, full chain from clean.

| check | result |
|---|---|
| **Stage 4b — JS fixed point** | `eco-boot-2.js == eco-boot-3.js` ✅ |
| Stage 5 `eco-compiler.mlir` | 13,458,106 B — **byte-identical to the native emit** taken independently before the format pass |
| Stage 6 ELF | 74,185,240 B — **byte-identical to the independently lowered `eco-post`** |
| Stage 7a `eco-compiler-boot.mlir` | **identical to Stage 5's output (A == B)** |
| Stage 7b ELF | **identical to Stage 6's ELF** |
| **Stage 8c — native fixed point** | `eco-compiler-boot.mlir == eco-compiler-boot-2.mlir` (B == C) ✅ |

Two things worth keeping from this run beyond the gate itself:

1. **A == B at the FIRST native iteration.** A default flip normally needs one
   extra bootstrap iteration to propagate (A != B is propagation; the gate is
   B == C). A pure deletion of default-off code propagates nothing, so A == B
   directly — which is itself evidence that nothing the compiler emits moved.
2. **Stage 5's node-hosted output equals the native emit taken BEFORE the
   elm-format pass and the §6.4 comment restoration.** Those edits were
   therefore inert, as claimed, rather than merely assumed to be.

| Stage 9b — `eco` self-hosts to `eco-2` | ✅ completed; `bootstrap.stamp` written |

**Run note (honesty):** the bootstrap did not finish in ONE invocation. It
reached step 14 of 16 — past BOTH fixed-point checks — and was then killed
twice by the harness for low memory during Stage 9b, which runs the front-end
and the in-process LLVM backend in one process and is the heaviest step in the
tree on this 15 GB box. Nothing in the chain ever failed; the kills are
resource events. Resumed with nothing else running, Stage 9b completed and the
chain finished. The two gates this plan rests on, 4b and 8c, were green before
the first kill and were independently re-checked with `cmp`.

**Bonus equality:** `eco-2` came out byte-identical to `eco-compiler-boot`
(74,185,240 B). Stage 9b deliberately asserts NO `eco == eco-2` equality — it
is a self-host capability check — so this is not a gate, but it does say the
unified binary's in-process NativeDriver path and the standalone
lower-and-link path agree to the byte on this tree.

### 6.8 Gate 6 — call-stats Run 28 recorded (new baseline)

Full four-group table in `benchmarks/call-stats.md` Run 28; raw rows
`cs28-ref` / `cs28-bench` appended to `benchmarks/call-stats.tsv`.

| | reference (subst) | benchmark (solver+LSS) |
|---|---:|---:|
| wall | 642.1 s | 546.3 s |
| max RSS | 14,948,864 kB | 15,048,684 kB |
| `out.mlir` | 13,458,106 B | 13,458,106 B |
| coverage | 99.05 % | 99.05 % |
| fast-dispatch share | 0.00 % | **52.69 %** |
| static-target share | 83.88 % | **94.07 %** |

**Groups 1 and 2 are identical between the arms to the digit** — every coverage
cell and every stamping verdict — which is the protocol's workload-invariance
check, and it passes.

As §4 restated before the run, this is a BASELINE, not an equality gate. Run 27
is not a same-source arm for two compounding reasons: the workload lost ~2 % of
its source to this very change, and Run 27 predates `stamp.rootFoldDepth`, which
is what moved `k1` 115,504 → 145,053 and `kN` 34,954 → 2,586. The ratios that do
travel are flat to slightly up (coverage 99.05 % both; fast share 51.80 →
52.69 %; static-target 93.95 → 94.07 %), and the movement in the latter two
belongs to `rootFoldDepth`, not to this removal.
