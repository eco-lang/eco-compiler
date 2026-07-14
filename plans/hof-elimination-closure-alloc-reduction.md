# HOF Elimination — Closure Allocation Reduction

**Status:** H0 + H1 + H2 + H2.5 + H3 IMPLEMENTED 2026-07-14 (baselines + matrices in `benchmarks/closure-census-baseline.md` — native-stage-7a dynamic census still pending). Shipped: censuses; let-callee forwarding + chain closure DCE; case-body inlining (guard lift + cost-model decider fix); let-of-closure flattening; let-callee hoisting; `hofThreshold` (default 25, called-param heuristic); application merging (pipe-shape collapse, 5,188 merges on self-compile); faithful residual type (double-wrapped-arrow fix) with the ground-result guard removed and `exactOnly` retained by design; LSS-on re-gate (first flag-on corpus vs the new inliner, 1602/1602 genuine) + `defaultLss.enabled=True` ("solver implies LSS" — engine default stays subst, blocked on JS-hosted solver perf per the monosolver plan). fpi stays 4. Next: H4 (intra-function elision — build/gate under explicit solver+LSS configs until the engine default flips) → H5 (interprocedural capture flattening).
**Date:** 2026-07-13
**Input:** `/work/hof-elimination.md` (prioritized suggestions), deep code investigation (this doc supersedes the suggestion list)
**Goal:** Greatly reduce the number of closures allocated at runtime (`eco_alloc_closure` executions), measured on the self-compile workload and the E2E corpus.

---

## 1. Executive summary — what the investigation changed

The suggestion list in `hof-elimination.md` is directionally right but the code says the leverage is distributed differently:

1. **The inliner knob alone does nothing for allocations.** `betaReduce` and the direct-call inliner *always* let-bind arguments via `createBindings`/`wrapInLets` (`MonoInlineSimplify.elm:1262–1294`) — a lambda-literal argument is never substituted into call position, so after inlining `apR x f = f x` the lambda survives as `let f' = λ in f' x'`. No pass reduces that: `simplifyLets` (`:2361`) does dead-let elimination only and **explicitly excludes closures even at zero uses** (`:2375–2380`, let-rec sibling safety). The missing piece is a *let-bound-closure beta rule*, not a threshold.
2. **`apR` very likely already inlines.** Its body (`MonoCall f [x]`) costs 5+1+1 = 7 against threshold 10 (`computeCost`, `MonoInlineSimplify.elm:485–550`; check at `:620–625`). The ~3,000 apR specs the LSS census reported are *mono-time* counts, before InlineSimplify runs. H0 verifies this empirically; if confirmed, the "one-knob experiment" of the suggestion list is mis-aimed and Phase H1 (beta completion) is the actual unlock.
3. **Recursive HOFs (`List.foldl/map`, `Dict.foldl`, parser loops) can never inline** — SCC recursion guard (`:332–471`, checked at `:602`). Lambdas passed to them need a *different* mechanism: interprocedural capture flattening (Phase H5), not inlining. This is where `xs |> List.map (\x -> …)` allocations die.
4. **"Closure elision" splits into two very different pieces.** Intra-function elision (all uses are local stamped calls) is a small, cheap MLIR pattern (H4). Elision across a call boundary ("passed to a stamped site") means cloning the callee with flat capture parameters — that is H5, requires keyed LSS fan-out, and is the second-biggest lever.
5. **LSS is default-OFF** (`Config.elm:96 — defaultLss.enabled = False`). Every elision phase consumes AbiCloning stamps, so flipping singleton LSS on (H3) is a prerequisite, not an afterthought.
6. **Measurement doesn't exist.** There is no runtime closure-allocation counter, and the inliner's `Metrics` (`:40–46`) are computed but never logged. The LSS census's core lesson ("budget wasn't the limiter — the declines are shape-class") only emerged from counting; this plan is census-first (H0).

Re-prioritized order: **H0 measure → H1 beta completion → H2 HOF-aware inlining budget → H3 LSS default-on → H4 intra-function elision (+ zero-capture interning) → H5 interprocedural capture flattening → H6 coverage residuals → H7 M5 unions (design only)**.

### Non-goals

- Lambdas that escape into **data structures** (decoder values, `Task` callbacks, closures stored in records/lists). Those allocations are semantic; reducing their *cost* is the borrow-inference/RC track (`design_docs/globalopt/borrow-inference-design.md`), not this plan.
- The JS backend (`Generate/JavaScript/*` — it already shortcuts `apR` at `Expression.elm:678`).
- M5 unboxed capture unions *implementation* — H7 produces the design doc and a go/no-go, nothing more.

---

## 2. Current state (verified anchors)

### Pipeline order (all in `compiler/src/Builder/Generate.elm` + `Compiler/GlobalOpt/`)

| Stage | Anchor |
|---|---|
| Monomorphize (subst/solver) | `Generate.elm:783–794` |
| **InlineSimplify** | `Generate.elm:799–810` → `MonoInlineSimplify.optimize` (`:805`) |
| GlobalOpt P1 `wrapTopLevelCallables` | `MonoGlobalOptimize.elm:130` |
| GlobalOpt P2/P3 Staging solve + validate | `:134`, `:138` |
| GlobalOpt P4 `AbiCloning.abiCloningPass` (LSS stamping) | `:145` |
| GlobalOpt P5 `annotateCallStaging` | `:150` |
| MLIR codegen | `Generate/MLIR/*` |

### Inliner facts (`Compiler/GlobalOpt/MonoInlineSimplify.elm`)

- Cost model: leaves 1; Let/Destruct 2; If 2+…; List/Record/Tuple/Case 3+…; **Closure/Call/TailCall 5+contents** (`:509–516`). Threshold 10, `maxPerFunction` 1000, `fixpointIterations` 4 (`Config.elm:141–146`).
- Whitelist bypasses the threshold entirely (`:620–625`); built-in list is Bytes-API only (`defaultWhitelist:218–292`); config `inline.whitelist` is additive, `inline.blacklist` subtractive; config changes invalidate `d.dat` via `configHash` (`Config.elm:273` includes `thr=`/`wl=`).
- Beta reduction of *literal* closure calls exists (`betaReduce:1167`, sites `:1190/:1210/:1246`); direct-call inline sites at `:2176/:2232/:2264`. All bind args as fresh lets (`createBindings:1262`, `wrapInLets:1287`); `substituteAll:1297` is name→name renaming only.
- Guards that must survive any change: recursion SCC guard (`:602`), kernel-ref partial-app guard (`:2122–2140`, protects specialized kernel ABI), `MonoTailCall` never inlined (`:957`), partial-app rebuild widens head annotation to `LTop` (`:1213` — known precision loss).
- The Phase-5 exponential from the old `wrapInLets`-chain hazard is **mitigated**: `sourceArityForExpr` (`MonoGlobalOptimize.elm:1474`) extends a memoized `varSourceArity` env via `extendSourceArityEnv` (`:1617–1629`) instead of re-annotating. Deep let chains are linear now; keep as a watch item, not a blocker.

### Stamping / fast dispatch (`Compiler/GlobalOpt/AbiCloning.elm`, `Generate/MLIR/Expr.elm`)

- AbiCloning stamps `callInfo.fastEvaluator/captureAbi/closureKind` on singleton-set call sites via a representative instance (`stampCall:950–989`; `MemberInfo:140`, `LayoutGroup:152`, `siteFingerprint:176`). Stats: `dispatchUpgraded / declinedBlocked / declinedNoInstance / declinedShape / declinedAbiMismatch` (`:69–96`), printed at `Generate.elm:1239–1254`.
- Codegen: stamped calls emit `eco.papExtend` carrying `_fast_evaluator` + `_capture_abi` (`Expr.elm:1652`, `generateFastDispatchCall:1687–1769`); C++ lowering projects captures from the closure and calls the fast clone `<name>$cap` whose signature is `(captures…, params…) → result` (`EcoToLLVMClosures.cpp`, `Lambdas.elm:234`). **The closure object at a stamped site is only a capture container** — that is what elision exploits.
- Self-compile census (LSS on): `dispatchUpgraded=3140`, `declinedShape≈7542` (shape-class: PAP consumption, layout mismatch — *not* budget-class).

### Config & flags (`Compiler/Eco/Config.elm`)

- `InlineConfig { threshold=10, whitelist=[], blacklist=[], maxPerFunction=1000, fixpointIterations=4 }` (`:110–146`).
- `LssConfig { enabled=False, keyed=False, maxSetSize=8, maxSpecsPerGlobal=64, report=False }` (`:83–101`). LSS M1–M4 are implemented and were gated green (E2E 1584/1584 across subst/solver/LSS=1/keyed), but **both flags default off**.

### Runtime

- `eco_alloc_closure` in `runtime/src/allocator/RuntimeExports.cpp`; closure header carries fp/arity/n_values/unboxed_bitmap/result_kind. No allocation counters exist.

### Invariant constraints (from `design_docs/invariants.csv`)

- `REP_CLOSURE_001/002`, `CGEN_049`: 2-bit slot kinds, ≤26 capture slots; only Int/Float/Char unboxed; **Bool always `!eco.value`** (`FORBID_CLOSURE_001`).
- `CGEN_033/051/052/056`: papCreate arity rules; saturated papExtend result type = callee result type.
- `CGEN_060`: generic-mode papExtend (no `remaining_arity`) dispatches at runtime — **never elide those**.
- `CGEN_064`: unboxed-worker/wrapper precedent — PAP captures always reference the wrapper; H5 reuses this worker/wrapper architecture for closure params.
- `CGEN_CLOSURE_003/004/005`, `ABI_CLONE_001`: FV ⊆ params∪captures∪siblings; `_fast_evaluator`/`_capture_abi` attribute discipline; ≤1 capture ABI per closure param post-cloning.
- `FORBID_CLOSURE_002`: closure layout from SSA operand types + recorded bitmaps, never from MonoType.
- `REP_LLVM_001`: no `ptrtoint`-derived i64 live across `gc.statepoint` — flat capture passing raises live-root counts at statepoints (linear in N); aggregate-return lowering has a known SelectionDAG fragility (kMaxDirectFields≈3 for *results*; scalar args are fine but cap flat captures conservatively).
- LSS_001–010 (`invariants.csv:601–610`) — especially LSS_008 (srcLambda propagation through wrappers/inliner copies) and LSS_009 (representative stamping; wrapper-home + adopted synthetics are blockers).

### Verification discipline (applies to every gate below)

- Run test suites ONCE, tee to `/tmp/test_output.txt`, grep the file (CLAUDE.md rule).
- **E2E compile cache is env/config-blind** (`test/ElmE2ETestBase.hpp:432–438`, mtime-only): before any corpus gate under changed flags/config, `find /work/test -name "*.elm" | xargs touch`. Never wipe individual build dirs (corrupt-cache gotcha).
- **The corpus is shaped by today's flag-off pipeline** — every new optimization needs *targeted adversarial tests* that fail if the feature is broken while the corpus stays green (LSS 3.6 lesson). Precedent: `/work/test/elm/src/Lss*.elm`.
- The E2E harness swallows census stderr — run census workloads manually, not through the harness.
- Perf methodology: interleave A/B runs of self-compile (±3–5 s sequential drift makes back-to-back comparisons unreliable).
- Don't run `build/test/test` and `elm-tests` concurrently (`~/.eco` typed-artifacts race).

---

## 3. Phases

Summary table:

| Phase | What | Effort | Expected allocation impact | Risk |
|---|---|---|---|---|
| H0 | Measurement: runtime + static closure census | S | none (enables everything) | low |
| H1 | Beta completion: let-bound-closure forwarding + closure DCE | M | high (unlocks the pipe/monadic spine) | medium (capture/sinking correctness) |
| H2 | HOF-aware inlining budget (`hofThreshold`) + whitelist | S–M | high (with H1 in place) | medium (code growth, compile time) |
| H3 | LSS singleton default-on | S | none directly (prereq for H4/H5) | low (already gated once) |
| H4 | Intra-function elision (MLIR) + zero-capture interning | M | low–medium (census-gated) | low |
| H5 | Interprocedural capture flattening | L | high (recursive-HOF lambdas) | high |
| H6 | Stamp-coverage residuals (local-multi, wrapper-home, …) | M | medium (census-gated) | medium |
| H7 | M5 unboxed capture unions — design doc + go/no-go | M (design) | n/a | n/a |

H1/H2 and H3 are independent and can proceed in parallel. H4 needs H3. H5 needs H3 (+keyed for targeted globals) and benefits from H1/H2 having already deleted the easy sites.

---

### H0 — Measurement (do first, keep forever)

**H0.1 Runtime closure census.** In `runtime/src/allocator/RuntimeExports.cpp`, behind `ECO_CLOSURE_STATS=1`:
- A global open-addressed table keyed by evaluator `fp` (single mutator thread; plain increments; fixed 64Ki slots, overflow bucket counter).
- Count every `eco_alloc_closure` (and separately papExtend-driven reallocations if they allocate — verify while implementing).
- At runtime shutdown, dump to stderr: total count/bytes + `closure-alloc fp=0x… count=N` lines.
- `benchmarks/closure-census.sh`: symbolize fp values offline via `nm` on the binary (MLIR-generated syms are in the static symbol table), emit a ranked table `symbol count`.

**H0.2 Compiler-side reporting.** Behind `ECO_INLINE_REPORT=1` (env, mirroring `ECO_MONO_LSS_REPORT`):
- Log the existing `Metrics { inlineCount, betaReductions, letEliminations }` from `runInlineSimplifyPhase` (`Generate.elm:799–810`) — currently computed and dropped.
- Add: static `MonoClosure` node count in the post-inline graph, and per-global inline tallies for the top 20 inlined callees (answers "does apR already inline?" definitively).
- Static MLIR-level counts: `--text-mlir` dump + `grep -c 'eco.papCreate'` (bytecode `.mlir` files are binary — text dump required).

**H0.3 Baselines.** Record in `benchmarks/closure-census-baseline.md`:
- Self-compile (stage 7a) dynamic closure allocs: total + top-20 sites.
- E2E aggregate (run a representative subset manually — harness swallows stderr) + `stress-elm`.
- Static: papCreate count in self-compile text MLIR; inline metrics.
- Both LSS off and LSS=1 (touch-all-.elm first), so H3's flip has a before/after.

**Gate:** flags-off builds byte-identical (trivially — code paths are env-gated); one `--target full` run green; baseline tables committed.

**Open questions H0 answers:** does apR inline today; what fraction of dynamic allocs are zero-capture; is `Task.andThen`/`Json.Decode` kernel or Elm in eco's core (top-site symbols will say); how top-heavy the distribution is.

---

### H1 — Beta-reduction completion (the real unlock)

**Problem.** After any inline, args live as `let f' = λ in … f' x …`. No rule reduces a let-bound closure applied in callee position, and closure lets are never DCE'd. Every pipe/monadic inline therefore *keeps* its lambda allocation today.

**H1.1 Let-callee forwarding.** In `MonoInlineSimplify.elm`'s rewrite (fires inside the existing fixpoint, so it composes with inlining across iterations):

For `MonoLet (MonoDef f (MonoClosure info body t)) rest _` where:
- `countUsages f rest == 1` (verify `countUsages` covers capture lists of nested closures — audit before relying on it), and
- the single use is the *callee* of a `MonoCall`, and
- the path from the let to that use crosses **no `MonoClosure` boundary** (sinking an allocation into a nested lambda body would convert one alloc into per-invocation allocs — a pessimization; crossing `MonoIf`/`MonoCase` branches is fine, they execute ≤ once per entry),

rewrite atomically: drop the let, replace the use with the closure literal → the existing `betaReduce` (`:1167`) reduces it in the same pass. One rewrite, no separate DCE needed, no let-rec hazard (the binding is gone in the same step).

Notes:
- Captures in `info` reference outer names that remain in scope at the use site (freshening already guarantees uniqueness); recompute nothing.
- Partial application at the use (`numArgs < params`): allowed — betaReduce's partial branch produces a *smaller* closure; still a win, but v1 may restrict to saturated uses for simplicity.
- Also catches user-written `let f = \x -> … in f 1`, not just inliner residue.

**H1.2 Safe closure DCE (narrow).** Extend `simplifyLets` to drop a closure binding at `usageCount == 0` **only when** provenance is inliner-fresh (`mono_inline_N` names from `freshVar:651`) — these are non-recursive by construction, so the let-rec sibling concern (`:2375–2380` comment) doesn't apply. Leaves user-written dead closures alone (rare; can be revisited with a real sibling-aware analysis later).

**H1.3 Metrics.** Add `betaForwards` and `closureDCE` counters to `Metrics`; wire into H0.2 report.

**Adversarial tests** (new, `/work/test/elm/src/Hof*.elm` + a text-MLIR assertion mechanism):
- `x |> (\a -> a + 1) |> (\b -> b * 2)` → zero `eco.papCreate` in text MLIR, correct result at runtime.
- `Maybe.andThen (\x -> …)` / `Result.andThen` chains 3 deep → zero papCreate (requires H2 for andThen inlining; land the test flag-gated and enable at H2).
- Closure with captures forwarded into a call under a `case` branch → reduced; same shape under a *lambda* → NOT reduced (sinking guard).
- Behavioral tests under GC pressure (tiny nursery + `ECO_HEAP_VALIDATE`) for the reduced forms.

**Gate:** elm-tests baseline-identical (12991/12); `--target full` green; adversarial tests green; H0 census delta on self-compile recorded (expect a visible drop even at threshold 10 if apR/apL already inline); self-build fixed point re-established (build compiler with new compiler twice; rounds 2 vs 3 byte-identical); stage-7a wall time within ±3% (interleaved A/B).

**Risks:** substitution correctness (mitigate: reuse existing `substitute`/freshening; adversarial + fuzz via existing deep-structural fuzzers); accidental sinking (the MonoClosure-boundary guard is load-bearing — test it explicitly).

**Implementation lesson 2 (found by the elm-tests gate, 2026-07-13):**
forwarding is restricted to SATURATED uses (`args == params`) with a
GROUND (non-function) result type. Both violations share one latent
pre-existing bug: whenever beta-reduction leaves a residual closure that an
enclosing call applies — via the partial-rebuild branch (SKI `s k k`), or
via a curried def whose body is a lambda (`compose f g = \x -> …`) — the
application site carries the mono result type (`i64`) while the residual
closure's compiled body keeps the generic boxed ABI: a CGEN_056 violation
(saturated papExtend result type vs callee return type), caught by the
SKI-combinator and identity-composition unit fixtures. H2 follow-ups: (a)
fix the residual-closure typing itself, and (b) add let-callee HOISTING
(`(let d in f) a` → `let d in (f a)`, evaluation order d,f,a preserved) so
curried chains collapse fully instead of being skipped.

**Implementation lesson 1 (found by the first gate run, 2026-07-13):** the
forwarding decision MUST be made at the let-CHAIN level, not per-let. From an
inner let node, an EARLIER letrec sibling is an ancestor — invisible to any
subtree usage count — and mutual/recursive closures reference each other in
both directions, so a per-let count of 1 can hide a second reference in an
earlier sibling's captures (crash class: codegen `lookupVar: unbound
variable`). The shipped rule: a def forwards only when (a) it's a `MonoDef`
closure literal, (b) zero self-references in its own bound expr (recursive
closures), (c) zero uses in EARLIER siblings, (d) exactly one use across
LATER siblings' bounds + final body, provable callee position. Forwarding
into a LATER sibling's bound is evaluation-order safe (captures were already
in scope at the def's own position); into an EARLIER sibling's it is not.
`LetRecClosureTest`, `MutualLetRec*`, `ProcessSpawnKillHalfTest` are the
regression pins. The same chain-view reasoning was already needed by
`freshenLetChain` and now also by the H1.2 chain DCE — treat "any per-let
analysis of letrec chains" as a suspect pattern in H2+ work.

---

### H2 — HOF-aware inlining budget

#### H2.0 — Lift the case-body inlining refusal (INVESTIGATED 2026-07-13; prework, do first)

`getInlinableBody` refuses closures whose body is a `MonoCase`
(`MonoInlineSimplify.elm`, `isCase`), with the comment "eco.case … is a
terminator (no result value)". **That rationale is stale.** Verified against
dialect, codegen, and runtime behavior:

- `eco.case` is a VALUE-PRODUCING expression op, not a terminator:
  `Ops.td:268–331` (`SingleBlockImplicitTerminator<YieldOp>`, variadic
  results, no `Terminator` trait). The verifier enforces it
  (`EcoOps.cpp:130–288`): ≥1 result (void cases rejected), every alternative
  ends in `eco.yield` (never `eco.return`/`jump`/`crash`), yield operand
  types equal result types. Invariants CGEN_010/037/043/045/046/047/048/053/054
  are all marked enforced. Lowering materializes results as merge-block
  arguments (`EcoToLLVMControlFlow.cpp:147–291`, `eco.yield` → `cf.br`).
- Cases compile AND RUN in every expression position: function tail,
  let-bound, arithmetic operand, call argument — pinned by the new corpus
  test `test/elm/src/CasePositionProbe.elm` (mid-block
  `%9 = eco.case(…) : (!eco.value) -> i64` feeding `eco.int.add`; JIT-green).
  The "MonoCase-TAIL" assumption in `eco-case-terminator-design.md` describes
  the pre-`eco-case-yield` world; the yield design is what's implemented.
- Guard-lift experiment (temporary edit, reverted): with `Maybe.andThen`
  whitelisted, andThen inlines mechanically and a DIRECT saturated chain
  `andThen λ (andThen λ (parse n))` collapses COMPLETELY — `betaForwards=3`,
  zero papCreate/papExtend, pure nested value-producing cases — and runs
  correctly (`test/elm/src/AndThenProbe.elm`, kept as a behavioral corpus
  pin; its full collapse re-activates when H2.0 lands). `substitute` already
  renames the MonoCase scrutinee/root names and decider (:1528–1545), so
  beta-substitution over case bodies is sound.
- **Gap found — the pipe shape needs one more rewrite.** `m |> Maybe.andThen λ`
  reaches the inliner as a PARTIAL andThen application; `tryInlineCall`'s
  partial branch rebuilds it as a let-wrapped closure
  (`MonoDef f (MonoLet cb λ (MonoClosure …))`), which H1's forwarding cannot
  match (it requires a closure LITERAL). Result: 0 forwards, closures remain.
  Fix: **let-of-closure flattening** — rewrite
  `let f = (let cb = λ in clo) in body` ⇒ `let cb = λ; f = clo in body`
  (closure creation is pure; binding order d, clo is preserved), after which
  the existing forward+beta chain collapses the pipe shape too. Implement
  chain-level next to `forwardInChain`; this composes with lesson 2's
  let-callee hoisting follow-up but does not require it.

Work items (in order):

1. Remove the `isCase` refusals in `getInlinableBody` (closure-body and
   parameterless-define arms) and fix the stale `isCase` doc comment. Keep
   the case filter for `buildBodyLookup`'s consumer (the bytes-fusion
   reifier beta-reduces those bodies at reify time — verify its tolerance
   separately or filter at its call site).
2. Add let-of-closure flattening (chain-level rewrite in MonoInlineSimplify).
3. Adversarial tests beyond the two probes already landed: (a) a
   STRING-case-bodied helper inlined under an outer case —
   `EcoToLLVMControlFlow.cpp:105–110` rejects nested string cases inside
   SCF-converted outer cases via dynamic legality, the one real dialect
   caveat found; (b) int/chr/bool `case_kind` bodies inlined into expression
   positions; (c) a case-bodied helper inlined into a tail-recursive loop
   under GC pressure.
4. Gate: touch-all-.elm + `--target full`; elm-tests (12991/12 baseline);
   census delta — expect the monadic-spine drop this phase exists for.

Per the direction set for this work: NO name-based special-casing of
`andThen` in the general path. The guard lift + flattening is fully general
over `MonoCase` bodies. Intrinsics for specific `elm/*` functions remain a
fallback ONLY if a blocker emerges (none did in this investigation).

**Implementation lesson 4 (found by the H2 gate, 2026-07-13/14):** raising
the budget surfaced the partial-rebuild soundness gap as a RUNTIME
miscompile: `tryInlineCall`'s partial branch rebuilds a re-staged closure
(fresh single-stage `MFunction`, fresh lambdaId) whose arity metadata the
runtime typed-apply path cannot chain when a caller over-applies it —
`spliceArgsForSaturatedCall` assertion; `CombinatorB*` (point-free S/K
combinators) and `SolverLayoutStepMonadTest` are the pins. Containment
shipped: hofBudget-admitted candidates are **exact-application-only**
(`exactOnly` in the candidates index); legacy (≤ threshold) and whitelisted
candidates keep pre-H2 privileges. Consequences: (a) the pipe shape
`m |> andThen λ` does NOT collapse yet (partial application of an exactOnly
candidate) — most of the self-compile spine is pipe-shaped, so hof=25's
measured win dropped from +35% to +1.9% betaForwards; (b) fixing the
partial-rebuild staging/typing (one bug, three manifestations: forwarding
ground-result guard, CGEN_056 elm-tests fixtures, this assert) is now THE
highest-leverage single fix in the whole plan — it unlocks pipe-shaped
collapse everywhere and lets three guards relax. Also: let-callee hoisting
(lesson 2's follow-up (b)) SHIPPED as part of this fix round.

**Implementation lesson 3 (found while landing H2.0, 2026-07-13):** the cost
model had a hole the case guard was masking — `computeCost` for `MonoCase`
summed only the JUMP-table branches, not the decider's `Inline` leaf bodies,
so any case-bodied function cost ~3 regardless of size and `Maybe.andThen`
inlined at threshold 10 the moment the guard lifted. Fixed with
`computeCostDecider` (Inline leaves counted, 1 per Chain/FanOut node).
General rule: lifting a categorical guard can expose every downstream model
that the guard was accidentally protecting — audit cost/eligibility models
that mention the guarded construct before lifting.

**Design.** Don't raise the global threshold (inflates all code). Add a second budget for callees where beta-reduction potential exists:

- `InlineConfig.hofThreshold : Int` (default = `threshold`, so behavior is unchanged until configured; decoder + `configHash` update in `Config.elm` — the hash keeps `d.dat` sound).
- In `initRewriteCtx` (`:579–648`): a candidate uses `hofThreshold` instead of `threshold` when some parameter is function-typed (`MFunction`) **and that parameter appears in callee position in the body** (the "called-param" check — distinguishes `Maybe.andThen` (case + call: win) from `Task.andThen`-shaped bodies that merely *store* the callback into a structure (no win, pure code growth)).
- Keep the 5-per-closure body charge unchanged — it correctly penalizes bodies that allocate.
- Whitelist additions only for census-proven outliers the heuristic misses.

**Experiment matrix** (self-compile + corpus, H0 metrics): `hofThreshold ∈ {10, 25, 40}` × `fixpointIterations ∈ {4, 6}` (deep `andThen` chains need iterations to cascade). Measure: dynamic allocs, static papCreate, binary size, stage-7a compile time AND runtime (self-compile is both — the compiled compiler is the benchmark program), InlineSimplify pass time.

**Pick defaults and bake** into `Config.elm` `default`.

**Gate:** full matrix table committed; chosen default: `--target full` green (touch-all-.elm — config change!), elm-tests green, self-build fixed point, binary size growth ≤ ~3% or explicit sign-off, stage-7a compile time within +3%. Watch: `annotateCallStaging` time (mitigated but monitor), GC pressure from larger frames (heap-profile script exists: `plans/heap-profile-script.md`).

**Interaction note:** more inlining ⇒ more verbatim closure copies ⇒ LSS M3.5 representative stamping absorbs them (LSS_008/009); also *fewer* HOF call sites survive to be stamped at all — re-run the LSS census after H2 before investing in H6.

---

### H2.5 — Partial-application soundness: merge, then (later) faithful rebuild

**Problem (lesson 4's root cause, stated precisely).** Both partial-inline
sites (`betaReduce`'s partial branch and `tryInlineCall`'s partial branch)
manufacture a residual closure for "the rest of the function":
fresh lambdaId, `srcLambda = Nothing`, and a FLATTENED single-stage type
`MFunction LTop remainingParams resultType`. That violates the design
principle `mono-uncurry-implementation.md` establishes — *partial
application is represented only via PAPs, never via nested closures* — in
two ways consumers notice: (a) STAGING — call sites elsewhere were compiled
against the ORIGINAL arrow's stage structure, and the runtime typed-apply
splices args per a static `EvalParamLayout` with no dynamic re-segmentation
(`spliceArgsForSaturatedCall` assert); (b) ABI — the rebuilt lambda's body
compiles with boxed returns while the application site is typed from the
mono result type (CGEN_056 mismatch). One bug, three guards: H1's
ground-result forwarding guard, H2's `exactOnly` containment, and the
elm-tests SKI/identity-composition fixtures.

**Step 1 — application merging (uncurry at the call site), IMPLEMENTED
2026-07-14.** Self-compile: 5,188 partialMerges, betaForwards 1,392 → 1,655
(+19% over baseline), closuresRemaining −233, artifact −0.9%, warm wall at
baseline. AndThenProbe pins the pipe collapse module-wide
(`CHECK-MLIR-NOT: eco.papCreate`) under the default config.
The pipe shape `m |> Maybe.andThen λ` is not semantically partial — it is a
saturated application split across two nodes. Make the inliner reunite it so
the partial-rebuild path is never entered:

- 1a. `specArities : Dict SpecId Int` in `RewriteCtx` (from `MonoDefine`
  closure params / `MonoTailFunc` params; recursive functions included —
  merging reshapes calls, it does not inline).
- 1b. Nested-call merge arm in `rewriteExpr`:
  `MonoCall (MonoCall f a1s) a2s` ⇒ `MonoCall f (a1s ++ a2s)` when `f` is a
  closure literal or a global with known arity and
  `len a1s + len a2s ≤ arity` (v1 refuses over-application merges: the inner
  call would have EXECUTED the body; ≤ keeps the inner call a pure PAP
  creation, so evaluation order is unaffected). Fresh `defaultCallInfo`;
  phase 5 recomputes staging metadata downstream.
- 1c. Generalize let-callee forwarding to STRICTLY-PARTIAL CALL bindings:
  `let f = g a1s in … f a2s …` (single use, callee position, same chain
  guards as closures, `len a1s < arity g` so binding evaluation creates a
  PAP and runs no body) forwards to `MonoCall g (a1s ++ a2s)` at the use,
  when the total ≤ arity. This is the piece that actually reaches the pipe
  shape — apR inlining leaves the partial application LET-BOUND, so the
  nested-call adjacency never appears literally.
- 1d. Metrics: `partialMerges` counter; report line.
- Tests: pipe-shaped andThen chain collapses under default config
  (AndThenProbe gains the module-wide `CHECK-MLIR-NOT: eco.papCreate`);
  CombinatorB*/SolverLayoutStepMonadTest stay green (their partial VALUES
  are not single-use callee-position bindings and must not change shape);
  self-compile betaForwards expected to recover past the unsound-era 1,571.

**Step 2 — faithful residual rebuild, IMPLEMENTED 2026-07-14.** The root
cause turned out to be a one-line type bug present in BOTH rebuild sites:
`peelCallResult` (Specialize.elm) already types a partial call node as the
PEELED arrow `MFunction anno remainingTypes r`, and the rebuild wrapped it
AGAIN (`MFunction LTop remTypes resultType`) — a double-wrapped arrow
declaring a phantom extra application level, which is what result-kind,
staging, and arity metadata all mis-derived from. Fix:
`residualClosureType` uses the peeled arrow verbatim (with a defensive
fallback to the legacy construction if the shape ever disagrees).

Outcome of the relaxation ladder:

  - H1's GROUND-RESULT forwarding guard: **removed**. An exact beta yields
    the source body (never a rebuild); an applied residual is consumed by
    hoisting + beta on later iterations; a stored one is a source-typed
    literal. Pins: SKI/identity-composition CGEN_056 unit fixtures (now
    reachable again and green), `HofCurriedForwardTest` (curried let-lambda
    collapses to zero papCreate), `HofResidualPartialTest` (a runtime-
    surviving literal-partial residual with the faithful type).
  - `betaReduce`'s partial branch: **kept, now faithful**. Literal-partial
    residuals are only ever applied within their true arity (the types
    guarantee it), so the fixed rebuild is sound there.
  - H2's `exactOnly`: **retained permanently, by design.** Partially
    inlining a GLOBAL replaces its PAP value with a genuinely re-arited
    closure while callers compiled against the global's curried TYPE may
    over-apply it, and the runtime typed-apply cannot chain over-application
    of a real closure. Per mono-uncurry's principle, partials of globals
    stay PAPs; application merging (step 1) collapses the profitable
    single-use shapes. The rejected alternative stands: dynamic runtime
    re-segmentation papers over statically wrong metadata and adds
    mid-chain GC-rooting obligations.

### H3 — LSS-on re-gate + "solver implies LSS" default (prerequisite for H4/H5)

M1–M4 shipped and were gated green, but `lss.enabled=False`. Elision consumes
stamps; make LSS the default wherever it CAN be.

**Correction (2026-07-14): LSS is a SOLVER-engine feature.** The
`EngineSubst` path of `selectMonomorphizer` never sees `lss`, and the engine
default must stay `subst` for now — the JS-hosted solver self-compile is
≥12× slower than subst (monosolver plan, Jul 12), which would break the
bootstrap and every guida-under-node workflow. So H3's flip is
`lss.enabled=True` with engine unchanged: inert for default (subst) users,
but **solver now implies LSS** — every solver run (E2E flag-on gates,
future engine-default flip, H4/H5 work) gets stamps without extra flags.
The ENGINE default flip is a separate, blocked item owned by the monosolver
plan (profile/fix JS-hosted solver perf first); H4/H5 must therefore be
built and gated with explicit solver+LSS configs until it lands.

- H3.0 Flag-on prep fix: `betaReduce`'s partial rebuild kept the source's
  `srcLambda` on a NON-verbatim residual (params/captures differ) —
  an LSS_009 impersonation risk under flag-on. Residuals now clear
  srcLambda/closureKind/captureAbi like `tryInlineCall`'s partial branch.
- H3.1 Re-gate at today's HEAD (post H1/H2/H2.5 — the corpus had NEVER run
  flag-on against the new inliner): touch-all-.elm, `--target full` under
  `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1`; elm-tests. Native self-build
  fixed point under solver+LSS: re-verify with the next bootstrap run
  (hours-scale; was proven Jul 13 pre-H1).
- H3.2 Flip `defaultLss.enabled = True`. **Keyed stays False** (the
  elm-aws-codegen pathological-input check from M4 is still outstanding;
  H5 opts into keyed per-global instead). Note: the `lss=1` hash token is
  value-based, so the flip invalidates all caches once.
- H3.3 Record post-flip census on flag-on probes (self-compile census under
  the JS-hosted solver is impractical — 12×; use corpus probes and defer
  the big census to a native solver run).

**Gate:** all of the above green; EngineDiff spot-check still runtime-benign
(known flag-off junk-spec divergence remains documented in the monosolver
plan).

---

### H4 — Intra-function closure elision (MLIR) + zero-capture interning

**H4.1 Elision pattern.** New eco-dialect pass `EcoClosureElide` (`runtime/src/codegen/Passes/`), running **before** `EcoGCPrepare`:

For each `eco.papCreate @f(%c1…%cn)` result `%p` carrying `_fast_evaluator @F`:
- If **every** use of `%p` is an `eco.papExtend` with matching `_fast_evaluator @F`, saturated (typed mode, `remaining_arity` consumed by the site's args — CGEN_052/056), rewrite each use to a direct `func.call @F$cap(%c1…%cn, args…)` with types per `_capture_abi` (CGEN_CLOSURE_005 prefix rule), then erase the papCreate.
- SSA scoping makes the escape check trivial: any other use (operand of another papCreate/construct/make/call/return, unsaturated extend, generic-mode extend per CGEN_060) blocks elision. Values used across `eco.case` region boundaries / block args: v1 skips (direct def→use only).
- Multi-use is fine (closure called twice → two direct calls, zero allocs, no code duplication — this is what H1 deliberately doesn't handle).
- Captures become SSA values live to the calls; RS4GC/EcoGCPrepare root them (`REP_LLVM_001` respected — they're `!eco.value`/primitives, no ptrtoint games). Cap: elide only when `n ≤ 8` captures (statepoint-pressure conservatism; config knob).

**H4.2 Zero-capture closure interning (census-gated).** If H0 shows material zero-capture allocs (likely: eta-wrappers from `wrapTopLevelCallables`, `always`-style helpers): allocate each zero-capture closure once (lazy static in old/perm generation; it's a leaf object — no scan concerns) and reuse. Precedent: string-literal interning with heap-generation epoch (HEAP_028+). Requires a new HEAP invariant for immortal closures; skip if census says it's noise.

**New invariant:** `CGEN_ELIDE_001` — "eco.papCreate may be erased only when every use is a saturated typed-mode eco.papExtend whose `_fast_evaluator` equals the papCreate's, rewritten to a direct call of the fast clone with the papCreate's capture operands as the `_capture_abi` prefix." Add to `invariants.csv`; add a verifier-side check (pattern-of-record in `pap-call-verifiers` machinery).

**Tests:** FileCheck dialect tests (precedent: `plans/bf-dialect-tests.md`); adversarial E2E: closure called in a tail-recursive loop, in both branches of a case, called twice — assert zero papCreate in text MLIR + correct under `ECO_HEAP_VALIDATE` with tiny nursery.

**Gate:** `--target full` (LSS on, touch-all-.elm) green; census delta recorded. Expectation is modest after H1 — the value is (a) multi-use shapes, (b) the machinery and verifier groundwork that H5 reuses.

---

### H5 — Interprocedural capture flattening (the recursive-HOF killer)

**Problem.** `List.foldl (\x acc -> …captures…) init xs`: the HOF is recursive (never inlines); with LSS the *dispatch* inside `foldl` is stamped fast, but the lambda still allocates at every call site execution. This is the dominant remaining class after H1/H2 (H0 census will confirm).

**Design — "closure-parameter worker cloning"** (extends AbiCloning; architecture precedent: CGEN_064 unboxed workers + wrappers):

For a spec `S` with closure-typed parameter `p` whose annotation is `LSet [m]`, where AbiCloning's index shows unanimous capture layout for `m` (ABI_CLONE_001) and **inside `S`** `p` is *only* called at stamped sites (not stored, not returned, not captured, not passed to a non-qualifying callee):
1. Emit clone `S_flat` with `p` replaced by `m`'s captures as typed parameters (per `captureAbi`); rewrite internal calls `p a…` → direct calls `m$cap(c1…cn, a…)`. Self-recursive tail calls thread the capture params through unchanged — this is exactly the `List.foldl` `MonoTailFunc` shape (AbiCloning already handles TailDef instances via the LSS transport work, cf. `specializeCycleFuncDef` TailDef peeling).
2. Rewrite qualifying callers: where the argument at `p`'s position is a closure literal (or a let-bound closure whose single consumer this is), pass the capture expressions directly and delete the papCreate.
3. Keep `S` (wrapper semantics) for non-qualifying callers.

**Prerequisites & scoping:**
- Per-set fan-out: in unkeyed mode multiple lambdas share one spec of `S` → multi-instance → no unanimity. H5 enables **keyed specialization per-global** for flattening targets (budget: existing `maxSpecsPerGlobal=64`; the M4 budget brake + LSS_010 join fallback already handle overflow soundly). Global keyed default remains off.
- v1 cuts: one closure param per spec; captures ≤ 6 (statepoint pressure — flattened captures are live across every GC in the loop); self-recursive `MonoTailFunc` + non-recursive callees only (no mutual cycles); `p` not re-passed to further callees (transitive flattening is v2).
- Where: new GlobalOpt phase between P4 (AbiCloning — needs its index) and P5 (`annotateCallStaging` — must see final call shapes). MonoAST level, because signatures and call sites both change (graph surgery of the kind AbiCloning already does).

**Milestones:**
- H5.1 *Flattenable census*: analysis-only pass counting qualifying (S, p, m) triples + dynamic weight via H0 top sites. Go/no-go and target list from data.
- H5.2 Transform for self-recursive TailFunc callees (`List.foldl/foldr/map`, `Dict.foldl` shapes) behind `ECO_FLATTEN=1`.
- H5.3 Broaden (non-recursive multi-call callees, transitive passing) as census justifies.

**New invariants:** `FLAT_001` (clone signature = captures prefix per captureAbi + original params minus p, staging preserved per GOPT rules), `FLAT_002` (wrapper retained; unstamped callers unaffected), `FLAT_003` (flattening only under unanimous layout + non-escaping p). Add invariant tests per the `callinfo-invariant-tests` pattern.

**Adversarial tests:** capturing lambda over Int/Float/Bool/boxed mix into `List.foldl` under forced tiny-nursery GC (the `kernelListMapN` stale-cursor bug class — GC-move the captures mid-loop); zero papCreate at the call site in text MLIR; a non-qualifying caller (lambda stored first) still works through the wrapper.

**Gate:** `--target full` (touch-all-.elm; LSS on + keyed-for-targets) green ×(subst, solver); elm-tests; self-build fixed point; census: expect the largest single drop of the plan; stage-7a runtime improvement recorded (this phase should also *speed up* the compiler itself — foldl/map spine dominates several passes).

**Risks:** highest of the plan — signature surgery + caller rewrites touch staging/CallInfo invariants (GOPT_001/003 validation after P3 has already run — re-run `validateClosureStaging` on the mutated graph as part of the phase); statepoint pressure in hot loops (cap + measure); keyed-mode compile-time cost on large inputs (budget brake exists; monitor with the M4 wall-time methodology).

---

### H6 — Stamp-coverage residuals (census-driven, demoted)

Only after the post-H5 census: the pre-investigation numbers (3,140 upgrades / 7,542 shape declines) describe a pipeline whose HOF spine H1/H2 will have partially deleted; investing here first would optimize sites that are about to vanish.

Candidate items, in the order the LSS plan documents them:
- **Local-multi transport** (`lss-lambda-set-specialization.md:860–866`): let-bound lambdas passed to HOFs don't transport members (annotation stays LTop). Pinned by `LssSingletonLetBoundLambdaTest`; census-gated follow-up.
- **Wrapper-home + adopted-synthetic blockers** (LSS_009 decline classes): teach staging wrappers/eta-wrappers to carry or forward capture layout so they stop blocking their member.
- **PAP-consumption / layout-mismatch shapes** within `declinedShape`: add a decline-reason breakdown counter first (one-line change in AbiCloning stats) — "declinedShape" is currently a single bucket; split it before deciding anything.

**Gate per item:** census delta justifying it, adversarial test, `--target full`.

---

### H7 — M5 unboxed capture unions (design only, last)

The PLDI'23 headline (k≤K lambda sets as stack-allocated tagged capture unions) remains fenced: it needs a new value representation and REP_*/HEAP_* siblings (`lss-lambda-set-specialization.md:1142–1151`). **H5 captures the k=1 case** — which the census shows dominates — at a fraction of the invariant risk. M5's residual value is k∈[2..maxSetSize] sets and match-dispatch without closure objects.

Deliverable: `design_docs/monomorphization/capture-union-representation.md` covering:
- Tagged union layout (discriminant + widest-slot struct), 2-bit kind encoding consistency (sibling invariant sketch `REP_STACK_CAPTURE_UNION` — same 00/01/10/11 slot kinds, Bool boxed per FORBID_CLOSURE_001, no embedded-constant compression per REP_CONSTANT_001/002).
- Boxing boundary rules (escape ⇒ box to heap closure), GC rooting of boxed slots inside a stack value, interaction with sret/aggregate lowering limits (kMaxDirectFields).
- Go/no-go criterion: post-H6 census share of allocations attributable to k≥2 sets and to escaping-but-small closures. If < ~10%, don't build it.

---

## 4. Changes vs `hof-elimination.md` (explicit re-prioritization)

| Original item | Disposition |
|---|---|
| 1. Inline the HOF spine ("one-knob") | **Split and corrected.** The knob (H2) is real but inert without beta completion (H1) — args are always let-bound and closure lets are never reduced or DCE'd. apR likely already inlines (cost 7 < 10); the blocker was never its threshold. |
| 2. Closure elision via AbiCloning index + escape check | **Split.** Intra-function → H4 (much simpler than proposed: SSA scoping makes escape checking trivial at MLIR level). "Passed to a stamped site" is interprocedural → H5, which is really callee cloning with flat captures, needs keyed LSS, and is promoted to the second-biggest lever. |
| 3. M5 small-set unboxed unions | **Demoted to design-only (H7).** H5 takes the k=1 majority at far lower invariant risk; build M5 only if the post-H6 census defends it. |
| 4. Matching more patterns (coverage) | **Demoted behind re-census (H6).** H1/H2 delete many of the sites the 7,542-decline census describes; measure again before investing. Split the `declinedShape` bucket first. |
| 5. Budget increase | **Still no** for allocation purposes — declines are shape-class. Keyed budget *does* matter for H5 target fan-out; handled there per-global. |
| (new) | H0 measurement infrastructure; H3 LSS default-on as an explicit phase; H4.2 zero-capture interning; sinking guard in H1 (correctness hazard absent from the original list). |

## 5. Open questions (answered by H0/H5.1, tracked here)

1. Does apR/apL/compose already inline at threshold 10? (H0.2 per-global tallies.)
2. What fraction of dynamic closure allocs are zero-capture? (H0.1 → gates H4.2.)
3. Are `Task.andThen` / `Json.Decode.*` Elm-defined or kernel in eco's core? (Determines whether the monadic spine win extends to them or they're data-escaping non-goals.)
4. How many (S, p, m) triples qualify for flattening, and what dynamic weight do they carry? (H5.1.)
5. Post-H2, what does the LSS decline histogram look like with `declinedShape` split into sub-reasons? (Gates H6.)
