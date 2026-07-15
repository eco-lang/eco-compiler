# HOF Elimination — Closure Allocation Reduction

**Status:** H0 + H1 + H2 + H2.5 + H3 + H4 + H5 IMPLEMENTED 2026-07-14 (baselines + matrices in `benchmarks/closure-census-baseline.md` — native-stage-7a dynamic census still pending). Shipped: censuses; let-callee forwarding + chain closure DCE; case-body inlining (guard lift + cost-model decider fix); let-of-closure flattening; let-callee hoisting; `hofThreshold` (default 25, called-param heuristic); application merging (pipe-shape collapse, 5,188 merges on self-compile); faithful residual type (double-wrapped-arrow fix) with the ground-result guard removed and `exactOnly` retained by design; LSS-on re-gate (first flag-on corpus vs the new inliner, 1602/1602 genuine) + `defaultLss.enabled=True` ("solver implies LSS" — engine default stays subst, blocked on JS-hosted solver perf per the monosolver plan); H4 as EcoPAPSimplify P4 multi-use elision + eco_intern_closure0 zero-capture interning (HEAP_033) — engine-independent (keys off `remaining_arity`, not LSS stamps), plus the ecoc `-emit=mlir-eco` no-pipeline bug and the codegen-harness RUN-parser substring bug fixed en route; H5 as call-site LOOPIFICATION (engine-independent, default-on — 779 loopifications on self-compile, closuresRemaining −5.2%; the LSS-keyed route stays as the v2 variable-argument extension). fpi stays 4. **H6.0 survey + H6.1 SHIPPED 2026-07-14** (extends −73.3% on the self-compile census; §H6.1 below); H6.2 U0 shipped, U2b implemented flag-off-only (flag-on unsound — §H6.2); H6.3 at V0 (post-H6.1 generic-dispatch extends re-ranked; V1/V2 remain census-gated). Next: fix U2b's staged-known capture-ABI interaction; then H6.3 V1/V2 or H7 per census.
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

**PLACEMENT DECISION (investigated 2026-07-14 — front-end vs MLIR).**
Question raised: should elision live in the Elm front end (GlobalOpt Phase
4.5 on MonoAST), where all other HOF elimination lives, instead of MLIR?
Findings:

1. **All papCreates originate from front-end-visible MonoClosure nodes**
   (`wrapTopLevelCallables` converts bare global/kernel refs in GlobalOpt
   Phase 1; the codegen fallback emitters at `Expr.elm:623/:840` are
   unreachable) — so front-end VISIBILITY is not the differentiator the
   original H4 text assumed.
2. **The decisive structural fact:** in MonoAST, a `MonoClosure` node is
   BOTH the lambda's definition template and its allocation site — codegen
   emits the `$cap`/`$clo` func.funcs from it. Front-end elision would have
   to split definition from allocation (a new marker/node + codegen
   emission-trigger changes + keeping the lambda alive past pruning). At
   MLIR level they are already split: the func.func exists independently
   and erasing the papCreate is trivially safe.
3. **The mechanism half already exists in MLIR:** `EcoPAPSimplify.cpp` is
   IMPLEMENTED and in the default pipeline (`EcoPipeline.cpp:63`,
   RCElimination → EcoPAPSimplify → … → EcoGCPrepare). Its P1 pattern is
   exactly single-use elision — saturated `papCreate @f(caps)` +
   `papExtend` (typed mode, single use) → `eco.call @f(caps ++ args)` with
   capture forwarding — plus P2 chain fusion. H4.1's remaining delta is
   the MULTI-USE case (every use a saturated typed extend) and any
   fast-stamped shapes P1's guards skip.
4. **The project's own placement principle** (pass_global_optimization
   theory): decisions (staging/ABI/calling conventions) belong to the
   front end; MLIR passes optimize canonical form; lowering implements.
   The DECISION here (which calls may target `$cap`, with what capture
   ABI) is already made by AbiCloning in the front end and transported via
   `_fast_evaluator`/`_capture_abi` — the established contract. What H4
   adds is a mechanical local rewrite over canonical ops: exactly the
   category the theory assigns to MLIR passes. All judgment-bearing HOF
   elimination (H1–H2.5, and H5's cloning) stays front-end.
5. **Front-end residual advantages** (smaller .mlir artifacts, census in
   one place) are real but minor; the census point is addressed by the
   runtime `ECO_CLOSURE_STATS` truth-teller. NOTE the measurement
   correction this investigation produced: `--text-mlir` papCreate counts
   are FRONT-END output, before EcoPAPSimplify runs — static counts
   overstate runtime allocations; use the runtime census for deltas.

**Verdict: MLIR — implemented as an additional pattern in the existing
`EcoPAPSimplify` pass (call it P4: multi-use elision), not a new pass.**
H5 is unaffected: it is decision-bearing (per-set spec cloning, signature
surgery) and stays a GlobalOpt phase.

**IMPLEMENTED 2026-07-14 (H4.1 + H4.2; full JIT suite 1606/1606).**
What landed, including two latent infrastructure bugs the work surfaced:

- **P4** in `EcoPAPSimplify.cpp`: papCreate-rooted pattern; every use must
  be the closure operand (#0) of a saturated typed-mode papExtend; each
  use rewrites to a direct call (P1's operand construction per use,
  targeting `_fast_evaluator` for two-clone closures), then the create is
  erased. Driver seeds now include PapCreateOps. Guards inherited from P1:
  self-capture refusal, args-array-convention refusal, symbol lookup.
  Pins: `pap_simplify_multi_use_elision{,_ir}.mlir` (the old
  `_no_transform` test pinned the OPPOSITE and was repurposed),
  `pap_simplify_multi_use_escape_guard.mlir` (newarg escape keeps the
  create), `pap_simplify_multi_use_fast_evaluator.mlir` ($cap targeting),
  `HofMultiUseElisionTest.elm` (end-to-end).
- **ecoc bug found**: `-emit=mlir-eco` built NO pipeline (dumped verified
  input) — every structural mlir-eco CHECK ever written was vacuous. Fixed
  (`runPipeline` now builds `buildEcoToEcoPipeline` for the non-lowering
  action). **Harness bug found**: the codegen RUN-line parser substring-
  matched `-emit=mlir-eco` as `-emit=mlir`; fixed with an explicit branch.
- **H4.2 interning**: `eco_intern_closure0(fp, arity, packed)` in the
  runtime — permanent singleton per wrapper fp via the string-literal
  `internLiteral` machinery (thread-local, epoch-synced, rooted slots);
  the papCreate lowering calls it for `num_captured == 0` &&
  no-self-capture creates, passing the Phase-C packed header word.
  Invariant HEAP_033. Gotcha for future runtime decls: new
  `getOrCreate*` helpers MUST be added to `materializeAllRuntimeDecls`
  (post-freeze assertion in parallel lowering — cost one debug round).
  The four `wrapper_*_return_*.mlir` tests pinned the old
  `eco_alloc_closure_k` callsite shape and were updated (K now rides in
  the packed word; still pinned via wrapper-name suffix + return type).
- Dynamic magnitude of interning remains a native-census item (the JIT
  harness cannot aggregate per-test allocation counts — known limitation).

**H4.1 Elision pattern.** Extend `EcoPAPSimplify`
(`runtime/src/codegen/Passes/EcoPAPSimplify.cpp`, already before
`EcoGCPrepare` in the pipeline):

For each `eco.papCreate @f(%c1…%cn)` result `%p`:
- If **every** use of `%p` is a saturated typed-mode `eco.papExtend`
  (P1's per-use conditions), rewrite each use to the direct call with the
  papCreate's capture operands forwarded (P1's rewrite, applied per use),
  then erase the papCreate. This generalizes P1 from "single use" to "all
  uses qualify"; for fast-stamped uses (`_fast_evaluator @F` matching the
  papCreate's), the direct call targets `@F$cap` with types per
  `_capture_abi` (CGEN_CLOSURE_005 prefix rule).
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

**IMPLEMENTED 2026-07-14 — with a design change that strengthens v1.**
The shipped form is **call-site loopification**, not LSS-keyed spec
cloning: when a SATURATED call of a loopifiable tail-recursive spec passes
a lambda LITERAL, the call rewrites to a local `MonoTailDef` loop — the
spec body copied (fresh lambda ids, freshened lets, freshened params),
self tail calls retargeted with the flattened entry dropped, and the
lambda literal substituted into the single internal callee position
(captures pre-substituted to their caller-scope variables; the existing
beta arm reduces it next fixpoint iteration). Rationale for the deviation:
the call-site literal makes the member identity self-evident, so v1 needs
NEITHER the solver engine NOR keyed fan-out — it is **engine-independent
and active by default** (`inline.loopify`, `ECO_INLINE_LOOPIFY=0` escape
hatch, `loop=` hash token), where the planned LSS-keyed form would have
been dark until the solver engine default lands. The allocation story
composes with H4: the λ's papCreate disappears at the front end, and the
local loop's own closure shell (pure tail recursion does NOT self-capture
— verified on `@_tail_f_0`; single saturated use) is elided downstream by
EcoPAPSimplify P1 — probe modules compile to ZERO papCreates end-to-end.

**Implementation lesson 5 (found by the first H5 gate):** the "Elm forbids
shadowing, so post-mono names are collision-free" reasoning from H1 holds
only WITHIN one source function. Loopification merges scopes ACROSS
functions: `List.member`'s capture `x` collided with `List.any`'s
destructured head `x`, rebinding the capture to the loop element
(`member False [True,True] == True`; EqualityBoolListMemberTest and four
siblings are the pins). Captures are therefore re-bound to INLINER-FRESH
names in prelude lets outside the loop — fresh names collide with nothing,
and the prelude keeps capture evaluation at the original position while
making the values ordinary free variables of the lifted loop. Rule for any
future cross-function code motion: NEVER substitute a moved body's names
to source-level names; always route through fresh intermediates.

Eligibility (buildLoopifiables/paramLoopifiable, MonoInlineSimplify): spec
is `MonoTailFunc`, body cost ≤ 2×hofBudget, no `MonoVarGlobal` self-ref;
per function-typed param — arity is the FULLY-PEELED arrow arity
(`flatArrowArity`; param types keep stage structure `MFunction [a]
(MFunction [b] r)` while internal call sites apply all stages flat — the
staged-currying twin of `peelCallResult`, and the first implementation
bug), and an accounting identity over `countUsages` proves the param is
consumed only as exactly ONE saturated callee call plus verbatim
tail-threading (uses inside nested closures / inner tail defs must be
zero; rebinding disqualifies). Call-site qualification: literal lambda,
param count == peeled arity, all captures are `MonoVarLocal` exprs.

Self-compile: **loopified=779** of 1,980 eligible specs, closuresRemaining
13,880 → 13,152 (−5.2%), beta +781 (the loopified lambdas reducing),
artifact +1.6% (loop-body copies). Pins: `HofFoldlLoopifyTest` (user HOF +
real `List.foldl`, GC pressure, `CHECK-MLIR: _tail_mono_inline`, zero
papCreates post-pass verified), `HofLoopifyGuardTest` (param-storage
refusal; captured multi-use closure shared correctly with the loop).

**Milestones (original; superseded as noted):**
- H5.1 *Flattenable census*: subsumed by the `loopified=N/M` report metric.
- H5.2 Transform for self-recursive TailFunc callees — SHIPPED as above.
- H5.3 Broaden: remaining as v2 — variable-argument callers (this is where
  the LSS-annotation route comes back), non-tail-recursive HOFs like
  `List.foldr` (a local general-recursive def would self-capture — needs a
  different shell), multi-stage literal lambdas, transitive passing.

**New invariants:** `FLAT_001` (clone signature = captures prefix per captureAbi + original params minus p, staging preserved per GOPT rules), `FLAT_002` (wrapper retained; unstamped callers unaffected), `FLAT_003` (flattening only under unanimous layout + non-escaping p). Add invariant tests per the `callinfo-invariant-tests` pattern.

**Adversarial tests:** capturing lambda over Int/Float/Bool/boxed mix into `List.foldl` under forced tiny-nursery GC (the `kernelListMapN` stale-cursor bug class — GC-move the captures mid-loop); zero papCreate at the call site in text MLIR; a non-qualifying caller (lambda stored first) still works through the wrapper.

**Gate:** `--target full` (touch-all-.elm; LSS on + keyed-for-targets) green ×(subst, solver); elm-tests; self-build fixed point; census: expect the largest single drop of the plan; stage-7a runtime improvement recorded (this phase should also *speed up* the compiler itself — foldl/map spine dominates several passes).

**Risks:** highest of the plan — signature surgery + caller rewrites touch staging/CallInfo invariants (GOPT_001/003 validation after P3 has already run — re-run `validateClosureStaging` on the mutated graph as part of the phase); statepoint pressure in hot loops (cap + measure); keyed-mode compile-time cost on large inputs (budget brake exists; monitor with the M4 wall-time methodology).

---

### H6 — Residual coverage: survey first, then data-chosen items

Restructured 2026-07-14 (post-H5): H6 is explicitly split into a
MEASUREMENT phase (H6.0) and implementation items (H6.1+) selected from
its output. Rationale: every phase so far deleted sites that previous
censuses described (the 3,140/7,542 numbers predate H1), and H6's two
concerns — dispatch coverage (LSS stamps; performance) and allocation
coverage (closures H1–H5 cannot remove) — target DIFFERENT residual
populations that only measurements can rank.

**H6.0 — the survey (do all three, then decide):**

- **H6.0a Dynamic census**: `ECO_CLOSURE_STATS=1` on NATIVE binaries
  (AOT-compiled workloads; the stage-7a self-compile when the bootstrap
  chain is available), symbolized via `benchmarks/closure-census.sh` —
  ranked evaluator table, post-EcoPAPSimplify truth. The master input:
  orders residual classes by real runtime weight.
- **H6.0b Decline histogram**: split AbiCloning's monolithic
  `declinedShape` counter into sub-reasons (PAP consumption / bucket miss
  / param-count / layout inequality / Char capture) so the flag-on census
  says WHICH shape gap dominates dispatch coverage.
- **H6.0c Static residual taxonomy**: classify surviving `MonoClosure`s
  in the post-inline graph by consumption context (stored-in-data /
  arg-to-tail-func / arg-to-other-global / arg-to-kernel / captured /
  multi-use-let / returned / other) — tells us which MECHANISM gap
  dominates allocation coverage; printed with `ECO_INLINE_REPORT=1`.

**H6.0 survey results (2026-07-14)** — data in
`benchmarks/closure-census-baseline.md` §H6.0:

- **H6.0b**: 100% of `declinedShape` declines in the flag-on batch are
  `arity` (PAP consumption); bucketMiss/layout/char/nonArrow all ZERO.
  Side-finding: H2–H5 eroded Lss stamp counts (dispatch pins now 0 —
  their annotated calls were inlined away; surviving sites still stamp).
- **H6.0c**: self-compile taxonomy of 13,165 residuals: let-bound 51%
  (overstates — P1/P4 elide the all-saturated subset downstream),
  arg-to-global 31%, arg-to-ctor 9% (semantic, out of scope), value 5%,
  arg-to-tailfunc 2.5%, arg-to-loopifiable 0.5%.
- **H6.0a**: probe native census = 1 closure alloc / 20k iterations
  (H4.2 intern). Flagship lowering of the self-compile artifact exposed a
  LATENT MISCOMPILE: escaped-taildef Char captures were typed boxed in
  the outlined shell but i16 at the papCreate site
  (`mlirTypeToApproxMonoType` stale `I32 -> MChar` arm; Char is I16).
  Pre-fix repro `CharCaptureEscapedTailDefTest.elm` segfaults under JIT
  too. Fixed `I16 -> MChar` in `Expr.elm`; full gate 1610/1610 zero-
  cached; regenerated artifact lowers clean and the native eco
  self-compiles BYTE-IDENTICALLY to the JS-hosted compiler.
  **Flagship census** (native eco compiling the full compiler, cold
  cache): creates=403.9M, extends=523.4M, distinct=7,115. Extends are
  99.996% on H4.2-interned singletons (Bitwise.and 156M — Dict/hash
  kernels): generic apply of known-arity PAPs is the #1 allocation
  source (~56% of events). Creates: top-50 = 68%; dominated by
  TypeCheck.IO monadic-bind continuations + UnionFind/IORef reader
  lambdas that ESCAPE into the returned IO value (arg-to-global/
  stored-data classes — not inliner misses).

**H6.1–H6.3 — the data-chosen items** (numbered 2026-07-14 from the
survey; each starts with a DESIGN INVESTIGATION, and implementation is
gated on that design plus the usual census-delta + adversarial test +
`--target full` discipline). Standing constraints from review: STATIC
analysis only — no runtime fast path unless the static routes measurably
exhaust (<few % residual left); NO per-module intrinsics — every
mechanism must be general (the elm/* kernels dominate the ranking only
because Array/Dict internals are hot, and the tail is compiler-own code).

#### H6.1 — Saturated PAP-chain elision (~56% of dynamic allocation events)

**Investigated 2026-07-14 — both root causes found; implementation-ready.**

*The shape.* "Interned known-arity PAPs" = the runtime POPULATION (H4.2
singletons whose underlying arity sits in the closure header), not a
mechanism. `Array_setHelp_$_350` is the flagship (elm/core source:
`Bitwise.and bitMask <| Bitwise.shiftRightZfBy shift index`): after apL
inlining the front end emits `papCreate @Bitwise_and_$_138` →
`papExtend(bitMask) remaining=2` → `papExtend(shifted) remaining=1 → i64`
— callee, args, and saturation all statically visible in ONE function.
The direct-call styling of the SAME operation in the same function
compiles to the `eco.int.and` intrinsic; only the `<|` styling pays.

*Back-end root cause (PRIMARY — a bug, not a tuning gap).*
`FusePapExtendChainPattern` (P2, `EcoPAPSimplify.cpp`) DOES fire and
produces the fused saturated extend, but its comment "prevExtend will be
DCE'd since it now has no uses" is FALSE: `Eco_PapCreateOp` carries the
`Pure` trait (Ops.td:1169) so dead creates are DCE'd, but
`Eco_PapExtendOp` (Ops.td:1287) has no purity trait — correctly, since a
SATURATING extend calls arbitrary code — so the orphaned non-saturating
intermediate survives. Post-pass self-compile IR (`ecoc -emit=mlir-eco`,
NB: dump goes to STDERR): setHelp contains the dead `%2 =
papExtend(%0,%1)` AND the fused `%4 = papExtend(%0,%1,%3)`. Consequences:
(1) the dead extend EXECUTES at runtime — an allocated-and-discarded PAP
per execution (the census's Bitwise.and 156M / shiftLeftBy 94M); (2) the
dead extend keeps the papCreate multi-use, so P1
(`SaturatedPapToCallPattern`, requires `hasOneUse`) cannot convert the
fused saturated extend to a direct call, and P4 (requires every use
saturated) is blocked by the unsaturated dead use. Measured: **14,449 of
44,393 post-pass papExtend ops are dead** (results unused; 32.5% of the
module's extends).

*Back-end fix (F1+F2, `EcoPAPSimplify.cpp` — do this first):*
- **F1**: in `FusePapExtendChainPattern.matchAndRewrite`, after
  `rewriter.replaceOp(extendOp, fusedOp)`, add
  `rewriter.eraseOp(prevExtend)`. Safe: the pattern already verified
  `extendOp.getClosure().hasOneUse()` (prevExtend's only consumer was
  extendOp) and that prevExtend is NOT saturated (pure allocation, no
  call). Erasing via the rewriter keeps greedy-driver bookkeeping
  correct, and the cascade then runs in the same fixpoint: papCreate
  drops to one use → P1 converts the fused extend to `eco.call
  @Bitwise_and_$_138(%1,%3)` → the create is DCE'd via `Pure`.
- **F2 (P5, robustness)**: new `DeadPapExtendPattern`: erase a
  `PapExtendOp` whose result has no uses AND whose `remaining_arity`
  attr is present with `remaining > realNewargs` (strictly
  non-saturating — saturating extends call code and generic-mode extends
  without the attr may saturate at runtime; NEVER erase those). Strip GC
  root hints the same way P1/P2 do when measuring `realNewargs`. Add to
  the pattern set and rely on the existing extend-rooted seeding.
- **Tests**: new `test/codegen/pap_simplify_dead_extend_erase.mlir`
  (RUN `-emit=mlir-eco`; input = the setHelp shape; CHECK a direct
  `eco.call`, CHECK-NOT any `papExtend`) + audit the existing
  `pap_simplify_*.mlir` / `wrapper_*_return_*.mlir` pins — P1 now fires
  in places it previously could not, so pinned outputs may legitimately
  change. Gate: `--target full`, then rebuild the native eco (JS
  self-compile → `eco-boot-native` → census workflow from H6.0a) and
  re-census. **Acceptance: Bitwise.and/shiftLeftBy extends collapse from
  156M/94M to ~0; total extends drop is the headline number.**

*Front-end root cause (SECONDARY — confirmed by probe).* `specArities`
(`MonoInlineSimplify.elm` ~:1710) records arity ONLY for
`MonoDefine (MonoClosure …)` and `MonoTailFunc` nodes; `calleeArity`
(~:3194) therefore returns Nothing for POINT-FREE specs — kernel aliases
(`and = Elm.Kernel.Bitwise.and`, zero source params) and user aliases
(`userAnd = Bitwise.and`) — and the merge arm refuses by design.
`test/elm/src/MergeProbe.elm` pins this end-to-end: both alias styles
emit create+extend+extend while direct style emits `eco.int.and`.

*Front-end fix (F3, second wave — value: intrinsics instead of residual
calls, plus static papCreate reduction; measure after F1/F2):* extend the
`specArities` fold to cover non-closure-bodied defines by deriving the
FLAT arity from the spec's mono type (`flatArrowArity` — the H5 helper;
staged arrows must be fully peeled). Safety argument for merging into a
saturated `MonoCall`: direct saturated source calls to these same specs
already compile (setHelp's else-branch) — the calling convention accepts
the flat form. Audit the merge arm's over-application refusal so it
keeps refusing when the callee body could EXECUTE effects at the inner
stage; point-free alias bodies are value-only so the refusal can be
relaxed for exactly the class specArities now covers. After the fix,
tighten MergeProbe's directive to `CHECK-MLIR-NOT: papExtend`.

**H6.1 IMPLEMENTED + MEASURED 2026-07-14.** F1 (P2 erases its orphaned
intermediate) + F2 (P5 `DeadPapExtendPattern`: unused result + strictly
non-saturating only) shipped; gate 1612/1612 incl. new
`pap_simplify_dead_extend_erase.mlir`. **Census on the identical
artifact: extends 523.4M → 140.0M (−73.3%), total PAP events −41%,
output byte-identical.** Bitwise/Array chains eliminated entirely.
Remaining extends (140M, still ~all on interned singletons) = per-use
generic application of HOF-arg partials (`applySubstPure` 11.3M,
`typeEncoderS` 10.3M) + TypeCheck.IO combinators (map/traverseList ~20M
combined). F3 (front-end): the real root cause was `specArities`
skipping ALL point-free specs — kernel-BODIED defines get flat arity
from the kernel type (stored STAGED; the emitted wrapper and papCreate
`arity` attr use flatArrowArity — that is the correct merge bound),
global-bodied aliases chase links (fuel 4); plus VarKernel arms in
`calleeArity`/`ForwardPartialCall`. MergeProbe pins: `partialMerges=2`,
both `<|` chains intrinsify to `eco.int.and`. Gate 1612/1612.
Post-F1/F2 dead-extend recount with a FIXED detector: 9,805 → 7,940
(remaining = 7,252 dead-GENERIC extends P5 correctly refuses — may
saturate and call at runtime — plus 688 dead-but-SATURATING typed ones,
also correctly refused).

#### H6.2 — Stored monadic continuations (~22%+ of creates)

**Investigated 2026-07-14 — mechanism understood; U0 census + U2a are
implementation-ready, U2b needs a short design pass.**

*The shape.* `IO a = State -> (State, a)` (a TYPE ALIAS —
`System/TypeCheck/IO.elm:108`). `andThen f ma = \s0 -> …` returns a
lambda; mono-uncurry flattens it so the spec's ENTIRE body is one
`papCreate` of an arity-3 lambda capturing `(ma, f)`
(`System_TypeCheck_IO_andThen_$_10041` in the self-compile IR). The
inliner inlines andThen at every bind, so each bind allocates that
closure + the continuation literal at the site — the census's top
creates block (UF readers 34M/18M/7M, descriptor binds 17.7M…). The
chains do NOT collapse intra-function because the state application
`ma s0` happens in the CALLER's bind lambda (the IO value is returned
across the function boundary) — this is why no amount of intra-function
forwarding fixes it, and why it is NOT an inliner gap. Note the module
already hand-eta-expands `map`/`foldrM`/`foldM`/`mapM_` (they take `s0`
directly and are closure-free); `andThen`/`pure`/`apply` are not.

*Implementation ladder:*
- **U0 (measure first, ~half day)**: extend the `ECO_INLINE_REPORT`
  machinery (residualTaxonomy precedent) with a "function-typed results"
  census: count specs whose result mono type is `MFunction [_] _`, and
  classify each call site of such specs by consumption — (a) result
  applied in the same expression, (b) let-bound then applied
  intra-function, (c) escaping (returned / stored / passed). Decision
  input: (a)+(b) are collapsible by U2a alone; a (c)-dominated
  distribution (expected — binds return upward) requires U2b.
- **U2a (merge-arm relaxation, independently shippable)**: allow the
  H2.5 merge arm to merge OVER-applications `(f args) extra` when f's
  spec body is a pure closure-literal-returning expression (new
  side-index alongside `specArities`: `specResultClosureArity : Dict Int
  Int`, built in the same fold by matching defines whose body — after
  let-peeling — is a `MonoClosure` literal). The inner "body would have
  executed" objection vanishes for this class: the body only constructs
  the closure. After merging, the existing inline+beta+case machinery
  collapses the bind. Same treatment in `ForwardPartialCall` for the
  let-bound variant. Tests: a corpus probe with a let-bound
  `andThen`-style chain applied locally; census counter for merges via
  the new index.
- **U2b (result-arity raising — the real lever; design pass first)**:
  worker/wrapper cloning for specs with function-typed results: raised
  worker `f$W (params ++ [s])` whose body is `(origBody) s` (existing
  rewrites then collapse it), original spec becomes a thin wrapper
  returning the PAP of `f$W` (mono-uncurry compliant; escaping sites
  allocate exactly what they do today — no regression). Call-site
  rewrite rides U2a's merge (the wrapper IS a closure-literal-returning
  spec). Design questions to settle before coding: insertion point in
  the GlobalOpt phase order (must precede AbiCloning so stamps see final
  shapes; verify against `MonoGlobalOptimize` phase list), interaction
  with LSS annotations (raised workers change which closures exist),
  recursion through the raised set (binds calling binds — likely fine
  since raising is per-spec and the inliner fixpoint cleans up), and a
  budget (raise only specs whose U0 site-count crosses a threshold).
  Risk note: A4 taught that flattening State COPIES was a wall-clock
  wash — U2b targets CLOSURE ALLOCATION, a different denominator; the
  census delta, not wall time, is the primary gate (wall time reported
  alongside).
- **U1 (optional source A/B, cheap data)**: hand-eta-expand `andThen` in
  `System/TypeCheck/IO.elm` (one line, matches the module's existing
  style), self-compile, census. This is NOT the general fix (moves
  allocs from lambdas to PAPs at escaping sites) but calibrates how far
  source discipline alone goes — useful input to the U2b go/no-go.

This item's numbers double as the H7 (capture unions) go/no-go
population: whatever U2a+U2b cannot remove is small-k escaping-closure
territory.

**H6.2 STATUS 2026-07-14: U0 shipped (`function results:` line under
ECO_INLINE_REPORT); U2b implemented but EXPERIMENTAL AND FLAG-ON
UNSOUND — do not enable.** `inline.arityRaise` / `ECO_ARITY_RAISE=1` /
hash token `ar=1` (present only when on; default hash untouched).
`raiseStagedSpecs` runs before the inline fixpoint: closure-literal
bodies splice (no freshening needed — same-source-function params);
call-shaped bodies wrap as `MonoCall body svars` (deliberately
unbounded — closure-literal ARGS cost 5+body, so any real bind chain
blows a static bound). Two live findings from `RaiseProbe.elm` (the
miniature TypeCheck.IO — keep as the pin; flag-off it must print
`result: (24,18)`):
1. Raising erases inner lambdas whose sets still annotate USE-site
   types → AbiCloning stamped phantom singletons (garbage via stale
   `_capture_abi`). Mitigated: flag-on widens ALL annos
   (`Traverse.mapNodeTypes Mono.widenSets`).
2. RESOLVED 2026-07-15 (three layers, gate 1613/1613 with layers 1+3
   UNCONDITIONAL on the default path):
   - **Layer 1 (emission guard)**: cross-stage batches in the
     staged-known call emission are now fully GENERIC — no
     `_capture_abi`, no typed `remaining_arity`, `_call_kind`
     downgraded to segmentation_unknown (Expr.elm, `isCrossStage`).
     The old claims assumed the callee's stage-1 result is its own
     staged wrapper; that contract only holds for compiler-materialized
     wrapper chains. The self-compile contained ZERO of the old stamps,
     so nothing measurable was lost.
   - **Layer 2 (standalone audit): CONFIRMED STANDALONE FLAG-OFF BUG —
     and it found a SECOND one.** A recursive staged-result function
     (`mk : Int -> (Int -> Int)` below) hits the same stamp flag-off;
     worse, its SPEC is emitted as `(i64) -> (i64)` — monomorphization
     drops the middle arrow of a staged-result def under flat demand, so
     even after the layer-1 guard the P1 direct call dies at LLVM
     translation with `result type mismatch: ptr != i64`. This
     spec-typing producer bug (peelCallResult/demand-flattening family)
     is OPEN; repro (was `StagedResultProbe.elm`, removed from the
     corpus because elm tests have no XFAIL):

         mk : Int -> (Int -> Int)
         mk a =
             if a <= 0 then \b -> b + 1000
             else if modBy 2 a == 0 then \b -> a + b
             else mk (a - 1)

         use : Int -> Int
         use n = mk n (n * 10)    -- expect (use 4, use 3, use 0) == (44, 32, 1000)

   - **Layer 3 (cascade stall)**: `f a s1` is ONE MonoCall carrying both
     stages' args, so `ForwardClosure`'s exact-arity check never fired
     for 1-param literals and the collapse stalled at its first link.
     The consumer now betas the FIRST stage exactly and re-applies the
     rest to the result (evaluation-order identical; hoisting + merge
     consume the residual). RaiseProbe flag-on: `closuresRemaining 3 →
     0`, pap ops 12 → 6, `result: (24, 18)` correct.
   - **Layer 5 (2026-07-15/16, single-alloc follow-up): PAP-EXTEND
     KIND-ENCODING SPLIT fixed — but the flag-on flake it was suspected
     of causing REMAINS OPEN.** The real latent hole: `eco_pap_extend`
     stored caller-encoded args RAW and OR-merged the caller's kind
     bitmap over the closure's declared kind map, splitting the GC's
     view from the stored representation in both directions
     (boxed-on-primitive-slot = GC-invisible pointer;
     primitive-on-boxed-slot = misread). Fixed unconditionally: args are
     converted to the slot's DECLARED kind at store time (the contract
     the GenericApplyBoxing unit-test file documents; those tests pinned
     the old mechanism and now declare slot kinds at create, as real
     typed wrappers do). Suite 1615/1615.
     **Flake status — open, next session's entry point.** Full matrix:
     h62on2 (pre-round) 3/3 stable; h62on3 (apR-exclusion + fusion)
     ~2-3/3 crash; h62on3 relowered with fusion DISABLED still crashes →
     fusion exonerated; broad pap-fix binary 4/4 stable ONCE then an
     identical rebuild 3/3 crash → that stability was LUCK, the
     conversion fix is principled but not the live hole; narrowed
     (unbox-only) fix also 3/3 crash. The one constant in every flaky
     binary is the apR-exclusion's extra inline/hoist/beta collapsing
     (flag-on-only code; flag-off unaffected). Prime suspect: GC root
     hints across the layer-3 first-stage-split residual shapes.
     Stats-on vs stats-off shifts the flake (a heap-layout-sensitive
     corruption); NEVER trust single stability runs on this class —
     3-4 repeats minimum. Flag-on census from the one passing run:
     creates 261.0M / extends 218.5M = 479.5M events, −12% vs flag-off
     (pre-round flag-on was +21%) — indicative, not settled, until the
     flake is fixed.
   - **Layer 4 (2026-07-15, found by the compiler-scale segfault):
     DESTRUCTURE-BINDER CAPTURE in the inliner's alpha-renamer.**
     `freshenLetBoundNames` renamed MonoDef/MonoTailDef binders in
     instantiated bodies but passed `MonoDestruct` binders through
     verbatim. Raised `andThen`'s body (`let (s1, a) = ma s0 in f a s1`)
     inlines RAW into thousands of callers; wherever a caller had its own
     `a` in scope and used it after the inlined segment
     (`constrainTupleWithIds`' source param `a`), the reference resolved
     to the bind result — gdb showed `constrainWithIds` receiving a
     Variable where a Can.Expr belonged, segfaulting on the tag load at
     entry. Diagnosis chain: symbolized native backtrace → IR read of the
     collapsed caller (`11203(%arg0, %7=flexVar, %11)` — args
     scrambled exactly one binder late) → minimal pin (`RaiseProbe.elm`
     probe2: `212` instead of `512` pre-fix, flag-on; flag-off the
     closure boundary shields today's inlinable bodies — both
     `DestructCaptureTest.elm` shapes print correctly — so this is
     latent-but-unreached flag-off). Fix (UNCONDITIONAL): the
     `MonoDestruct` arm now freshens the binder (fresh name +
     `renameLocal` over its scope, inner freshened first per the
     def-rename policy).

#### H6.3 — Stamp coverage for dispatch (dispatch value, not allocation)

**Scoped 2026-07-14; strictly after H6.1 re-census (H6.1 removes the
biggest extend traffic, so dispatch value must be re-ranked first).**

- **V0**: re-census on the post-H6.1 native eco; if generic-dispatch
  extends are now <a few % of events, stop here.
- **V1 (local-multi transport)**: the documented v1 precision gap
  (`lss-lambda-set-specialization.md` §M3 transport list): let-bound
  lambdas passed to HOFs skip `enrichFromEnv`, anno stays LTop → no
  stamp. Fix = transport the member set through local-multi targets in
  `Translate` (the `demandUnifyRoot`/`lssRootAnn` machinery is the
  precedent); flip `LssSingletonLetBoundLambdaTest` from gap-pin to
  stamp-pin (`dispatchUpgraded=1`).
- **V2 (wrapper-home / adopted-synthetic unblocking)**: the two LSS_009
  blocker classes recorded in the M3.5 notes — representative stamping
  currently declines when the member's home is a staging wrapper or an
  adopted synthetic. Work is in `AbiCloning.instanceMember` /
  `resolveRepresentative` plus the LSS_008 wrapper-identity rules.
- **V3 (PAP-shape stamping — design only until V1/V2 are censused)**:
  H6.0b showed 100% of remaining shape declines are `arity` (a PAP of
  the instance flows, argCount < first-stage arity). Sketch: extend the
  site fingerprint with an applied-prefix count k; a stamped PAP site
  calls `$cap` with the k stored PAP args loaded from the (uniform,
  boxed) PAP arg slots plus the site args — an `emitFastClosureCall`
  variant. This is the only remaining shape class, but it needs its own
  capture-ABI-adjacent invariant work; do not start it on dispatch
  grounds alone.
- All V-items are solver+LSS flag-on work: every gate uses the
  genuineness protocol (explicit-compile byte-compare + touch-all-.elm
  before flag-on corpus runs).

**Demoted by measurement (do not build without new data):** H5 v2
variable-arg loopification (arg-to-loopifiable = 0.5% dynamic);
`List.foldr`-class loop vehicles (the 31% static arg-to-global turned
out to be monadic binds, not folds — re-check per-symbol first).

Anything under a few percent of dynamic allocations does not get built —
and the same numbers feed H7's ~10% go/no-go directly.

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
