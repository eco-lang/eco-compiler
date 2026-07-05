# Symmetric Constraint-Join Experiment: Quiescence-Before-Defaulting, Second Attempt

## Status: IMPLEMENTED & GREEN (2026-07-05) — 12,868 unit + 1,547 E2E, 0 failures

> **D7 landed (2026-07-05, follow-up, still 12,868 + 1,547 green) — a CORRECTED,
> narrower D7 than the parent plan specified.** The plan's D7 said replace the
> number-multi gate with the uniform predicate `Mono.containsAnyMVar (applySubstFV
> …)`. That is **wrong**: it SIGABRTs `RecordNarrow08NoDestructure` — a polymorphic
> record with a boxed `List a` field is `containsAnyMVar` but NOT
> `isNumericFixableShape`, and routing it into the seed-and-emit value-multi branch
> mishandles it. Empirically, `isNumericFixableShape` is a **structural guard**
> (excludes shapes the machinery can't re-type), not a prediction. The actual
> band-aid is the third, provenance/prediction conjunct. So the gate became:
>
> ```
> else if hasUnresolvedNumberVar … && isNumericFixableShape (applySubstFV …) then
> ```
>
> i.e. the two structural guards are KEPT and only
> `(isNumericDataRhs || (isScalarNumberShape && demandedNumericUseType /= Nothing))`
> is dropped. That conjunct predicted, from RHS provenance + a demand-replay Float
> prediction, whether deferral was worth the risk of an eager Int commit; under
> quiescence the eager seed is open (never Int-committed), so every number-fixable
> binding is admitted unconditionally and the use-site machinery detects any Float
> use. Verified this does NOT reintroduce the boxed-custom SIGSEGV class the guard
> warned about (EmbeddedNothing 9/9, UnboxWrapper 5/5, NumberGeneric 4/4,
> Maybe/Custom/Boxed all green) — because the number stays open, not eager-boxed.
>
> **Deleted (6 functions, cascade-verified dead after the gate change):**
> `isNumericDataRhs`, `isScalarNumberShape`, and `isNumericDataRhs`'s exclusive
> helpers `isCtorGlobal`, `globalCallSafeToFire`, `canResultType`, plus `getDefRhs`
> (its only use was the removed gate).
> **Not deleted by D7 alone** (the parent plan's D8 "certain" list overstated this):
> `hasUnresolvedNumberVar` (also used by `shouldUseValueMulti`/`isNumberMultiTarget`)
> and `isNumericFixableShape` (now the gate's structural guard) stay. **Demand
> replay was NOW fully retired in a follow-up (see below).**

> **Demand replay RETIRED via body-first Destruct (2026-07-05, still 12,868 + 1,547
> green).** The last consumer of the replay cluster was the **Destruct
> `floatDemand`** look-ahead — the sole Float detector for destructor-bound numbers
> (`let (a,_) = p in a * 1.5`). It was replaced by a body-first restructure that
> discovers the demand from the body's uses instead of predicting it:
>   - New `specializeNumberDestruct`: seed the destructor-bound var `dname` as a
>     number-multi target (a placeholder valueMulti entry with an eager-Int
>     instance), bind it open in varEnv, specialize the BODY FIRST so its uses
>     record per-shape instances via `resolveNumberMultiVarRef` (the state-threaded
>     valueMulti channel — the propagation route the earlier "J5 mis-steer" got
>     wrong; the demand is a subst binding surfaced as an instance, not an MVarEnv
>     taint), then at pop emit one `MonoDestruct` per recorded instance, each
>     projecting from a root instance materialised at the demanded Int/Float type.
>     This inverts the historical "specialize destructor, then body" order.
>   - The Destruct case DIVERTS to it only when `isNumberMultiTarget rootName &&
>     fieldIsScalarNumber && canRefinePath` (buildPartialContainer succeeds);
>     everything else (tuple/nested/`rest` fields, list-index `ArrayIndex` paths)
>     stays on the extracted `specializeGeneralDestruct` (the old body, unchanged),
>     which now needs no `floatDemand` (guard simplified to
>     `not (containsAnyMVar rootCanType)`, `destrMonoType0 = eagerLeaf`).
>   - The whole cluster is deleted: `isTargetLocal`, `callArgDemands`,
>     `collectNumericDemands`, `collectNumericDemandsDef`,
>     `collectChoiceNumericDemands`, `demandedNumericUseType`.
>
> Bugs found and fixed along the way (all crashes, caught by the unit suite's
> synthetic-program invariant sweeps, not the E2E): (1) divert too broad → tuple
> and nested-tuple fields entered the scalar path and crashed → narrowed to a
> scalar-number field; (2) list-destructure (`ArrayIndex`) → `buildPartialContainer`
> returns `Nothing` → dropped destructor → `lookupVar: unbound variable head` →
> added the `canRefinePath` guard; (3) `instanceKey` must apply `refreshConstraints`
> to match `getOrCreateValueInstance`'s internal J3 key, or `tagValueInstance…`
> crashes on a missing key; (4) the eager-Int destructor is emitted only if `dname`
> is actually referenced in the body (`exprReferencesLocal`), to avoid spurious dead
> root instances. **J5 is orthogonal and remains undone** — it does not, on its own,
> retire replay (that was the earlier mis-diagnosis); it is a separate Join-R
> robustness improvement.

> **Dead-code cleanup (2026-07-05, follow-up, still 12,868 + 1,547 green).** Two
> band-aids that the flip made genuinely dead were deleted:
>   - **`applySubstKeepNumber` fork** (`applySubstKeepNumber` +
>     `applySubstLambdaChainKeepNumber` + `resolveMonoVarsKeepNumber` +
>     `resolveMonoVarsKeepNumberHelp`, ~180 lines): the flip made `applySubst`
>     itself preserve `CNumber`, so this counter-operator clone is now provably
>     equal to `Tuple.first (applySubst …)` (env is never mutated). Its 4 callers
>     in `Specialize.elm` were repointed.
>   - **`forceCNumberToInt`** (the identity fossil) + all **73** no-op call
>     wrappers unwrapped, and the function + its export/@docs removed.
> **NOT deleted — still load-bearing in this (non-D7) implementation:** demand
> replay (S4), number-multi/localMulti/valueMulti, the gate predicates, and the
> Pending variants. A recon data-flow trace confirmed demand replay is the SOLE
> detector of the Float use for two shapes — a scalar `number` let with a
> case/if/local-call RHS used at Float, and a destructor-bound `number` used at
> Float — because neither shape otherwise reaches the value-multi stack, so
> `resolveNumberMultiVarRef` never fires for it. Removing replay reintroduces the
> `mul_Float(f64,i64)` miscompiles. These become removable only with D7 (the
> uniform let-deferral gate + observe-then-emit restructuring), a separate effort
> the parent plan scopes out; that is the remaining cleanup, not dead code today.

> **Outcome.** The experiment succeeded. `number` is no longer prematurely
> defaulted to Int: `applySubst` preserves `MVar _ CNumber` residuals through the
> whole fixpoint, and a single post-Prune `resolveResidualNumbers` closing pass
> discharges them to `MInt`. All 12,868 unit tests (incl. the MONO_025
> "3-var-collision" canary) and all 1,547 E2E tests pass — including every one of
> the 31 tests that failed in attempt #1.
>
> **The key finding: J2 was load-bearing, not optional.** The plan was
> implemented first WITHOUT J2 (Join-W + Join-R + refresh + table-consulting
> closing + the post-Prune/ctorShapes confound fix). That still failed the same
> 31 E2E tests — proving the confound fix and J1 alone were NOT the cause/cure.
> Tracing `Debug.log "x" (10 + 3)` (a SIGSEGV case) to its root showed the
> mechanism precisely:
>   1. D6 widened the PendingCall trigger to `containsAnyMVar`, so `10 + 3` (now
>      an open `MVar CNumber` result under the flip, where it was eager `MInt`
>      before) is DEFERRED as a `PendingCall`.
>   2. `resolveProcessedArg` later resolves that pending arg against `Debug.log`'s
>      `a` parameter — a boxed `CEcoValue` slot (PreserveVars ABI) — via
>      `TypeSubst.unifyExtend canType paramType`.
>   3. That unification goes through `unifyHelp`'s `Can.TVar` arm (canonical-vs-
>      mono), which bound the number canonical tvar TOWARD the boxed mono var —
>      **erasing the number to CEcoValue**. The arg was then typed `CEcoValue`
>      (boxed) while its value stayed an unboxed `i64` → `'i64' != '!llvm.ptr<1>'`
>      / SIGSEGV at the call boundary.
> J1 (the `unifyMonoMono` mono-vs-mono join) never fires on this path because the
> erasure is canonical-vs-mono. **J2 — the same number-dominates join in
> `unifyHelp`'s `Can.TVar` arm — is what prevents it:** bind the boxed var toward
> the number var (open CNumber residual) + taint it, leave the number var open so
> it closes to Int, while the already-built boxed ABI slot (`funcMonoType`) still
> drives boxing at the boundary. Adding J2 turned the 31 failures green in one
> change with zero unit regressions.
>
> **What this means for the number root cause.** The eager default masked the
> number/boxed boundary by resolving numbers to `MInt` before they could reach a
> `CEcoValue` slot. The flip exposes the boundary; the symmetric join (J1 mono-
> mono + J2 canonical-mono, both "number dominates", both recording the class fact
> in the shared side table) is the honest boundary rule — no codegen change was
> needed after all, because the fix keeps the arg's producer type as Int and lets
> the existing immediate↔eco.value boxing (CGEN_001) do its job at the call. The
> earlier post-mortem's "needs a codegen-spanning boxing rule" conclusion was
> pessimistic: the rule belongs at unification (number-dominance), not codegen.
>
> **Env-threading audit (J5): deferred and, empirically, unnecessary for green.**
> The 45 env-dropping call sites were NOT threaded. Join-W is subst-carried
> (always threaded), and J2 leaves the number var open (closing to Int by the
> flip's default, no taint persistence required), so the primary routing/boundary
> correctness never depended on Join-R taint persistence. Join-R taints persist
> only at the ~8 already-threaded sites; that was sufficient. If a future change
> exposes a healed-copy hole, the audit list in the recon remains the map.
>
> **Files changed** (all in `compiler/src/Compiler/`): `Monomorphize/State.elm`
> (`taintNumber` + export); `Monomorphize/TypeSubst.elm` (flip 2 arms, J1 in
> `unifyMonoMono`, J2 in `unifyHelp`, `refreshConstraints` + export);
> `AST/Monomorphized.elm` (table-consulting `resolveNumberType` + export, D4 key
> as "I"); `Monomorphize/MonoTraverse.elm` (`mapNodeTypes` total type-mapper);
> `Monomorphize/Monomorphize.elm` (`resolveResidualNumbers` post-Prune closing
> pass over nodes + reverseMapping + ctorShapes, consulting final superVars);
> `Monomorphize/Specialize.elm` (D5 `isFullyMonomorphicType`, D6 PendingCall
> trigger, CNumber-aware `isNumericFixableShape`/`isScalarNumberShape`,
> `refreshConstraints` at the 4 key-construction sites).

## Status (original plan): Planning (experiment — bounded, revert-on-regression)

## Goal

Re-attempt the quiescence-before-defaulting flip
(`plans/number-quiescence-before-defaulting.md`, ATTEMPTED & REVERTED Jul 2026)
with the two additions that the first attempt's post-mortem identified as the
missing commutativity repair:

1. **A symmetric constraint join at var-var unification** — the constraint of a
   unified equivalence class is the join of its members' constraints
   (`CNumber ⊔ CEcoValue = CNumber`), independent of binding direction.
2. **Class-fact readers** — spec-key construction and the closing pass consult
   the *final* shared constraint state rather than trusting constraint
   annotations stamped into `MonoType` copies mid-fixpoint.

Success = the design goal ("`number` is never prematurely defaulted to Int;
CNumber residuals are discharged once, by a closing pass at the end") holds
with **all 12,868 unit tests and all 1,547 E2E tests green** — in particular
the 31 tests that failed in attempt #1 (checklist below).

This is explicitly an **experiment**: the first attempt's failure evidence is
confounded (see "Why this is worth re-running"), the mechanism here is
materially different from what was tested, and the protocol below includes a
decisive verdict path and a mandatory revert-on-regression rule.

## Context — read first

- `plans/number-quiescence-before-defaulting.md` — the parent plan (v2) and its
  **ATTEMPTED & REVERTED** post-mortem: root cause, the reusable verified
  pieces, and the revised scope. This experiment implements the parent plan's
  D1/D3/D4/D5/D6 deltas *plus* the join, and defers all deletions (S4, gates,
  keepNumber) exactly as before.
- Post-mortem essentials, restated:
  - The closing pass in attempt #1 was **total** — no open `CNumber` survived
    to codegen. The failures were **divergent copies**: the same logical
    value's type closed to `MInt` (i64) in one stamped copy and stayed
    `CEcoValue` (boxed) in a partner copy, because mid-fixpoint var-var
    unification erased the number-ness in one direction
    (`unifyMonoMono`'s `MVar/MVar` arm binds `var1 → var2` ignoring
    constraints), producing `'i64' != '!llvm.ptr<1>'` / SIGSEGV at boundaries
    (`Debug.log`, combinators, HOFs, custom-type cases).
  - **The evidence against the join is confounded.** The full-E2E run that
    failed 31/1547 had a (direction-forcing) join but ran the closing pass
    *before* Prune — so `ctorShapes`, recomputed by Prune with the
    non-defaulting `applySubst`, reached codegen with open `CNumber`
    (plausibly the custom-type failures on its own). The join was then removed
    *and* the closing moved after Prune in the same step; `IntAdd` still
    failed (the join-less erasure divergence — exactly what the join fixes).
    The cell {join × post-Prune closing with ctorShapes} was **never tested**.

## The mechanism

**Definitions.** A number var is *open* if unbound in the substitution. The
substitution's `MVar → MVar` bindings already form a union-find
(`TypeSubst.findRootVar` :121–164, with path compression that re-stamps
constraints via `constraintOf` :54). Constraints authoritatively live in the
shared side table `MVarEnv.superVars` (`constraintOf` recomputes from it; the
`Constraint` inside each stamped `MVar` copy is a cache).

**The join, two halves:**

- **Join-W (write side, substitution-carried — the router).** At every var-var
  unification where exactly one side is a number var, **the number var becomes
  the class representative**: bind the `CEcoValue` var toward the `CNumber`
  var, regardless of argument order. This is outcome-symmetric — `(num, eco)`
  and `(eco, num)` both produce `eco → num` — which is the direction-
  independence property this experiment tests. Because the class root is then a
  genuine number id (already in `superVars` from AssignMVarIds), `constraintOf
  root` is `CNumber` with **no new state**: path compression, `normalizeMonoType`,
  and every post-merge stamp inherit the correct constraint through machinery
  that already exists. Crucially the substitution is the *reliably threaded*
  state — every caller keeps the returned subst — so Join-W cannot be silently
  dropped.
- **Join-R (read side, side-table-carried — the healer).** Copies stamped
  *before* the merge still carry `MVar ecoId CEcoValue` with a stale id that
  the subst (per-work-item, discarded at item end) can no longer heal. So at
  each join, also record the fact in the shared table: insert the eco var's id
  into `superVars` as `Number`. Readers:
  1. **Key time**: a `refreshConstraints : MVarEnv -> MonoType -> MonoType`
     helper re-stamps every `MVar id _` to `MVar id (constraintOf id env)`
     before `toComparableMonoType`, so demands key by current class state
     (a number demand can never land in an erased-sentinel shared spec via a
     stale annotation).
  2. **Closing time**: `resolveNumberType` resolves `MVar id _` by looking `id`
     up in the **final** `superVars` — a pre-merge `CEcoValue`-stamped copy
     whose id was number-tainted closes to `MInt` like its partners.

**Why boxed contexts stay correct.** A number crossing into a genuinely-boxed
slot (`Debug.log`'s `a`, kernel PreserveVars ABIs) is a *boundary coercion*,
not a representation change: the producer side closes to `MInt`, the consumer
slot stays `eco.value`, and codegen's existing immediate↔eco.value boxing
(CGEN_001) inserts the box — the same treatment the eager-default baseline
gives it. The join must therefore only ever taint **per-call-site fresh scheme
instances** (scheme freshening already guarantees the callee's *body* vars are
not shared with any call site's instance vars), routing number demands to
concrete `_Int`-keyed specializations — the same routing eager defaulting
produced — while genuinely-erased demands keep boxed shared specs. Backward
discovery across uses of one let binding needs nothing new: per-use
instantiation vars mean no sideways propagation, and number-multi's
observe-then-emit at let-pop (kept, gates made CNumber-aware) supplies Int and
Float instances after all uses are seen.

**The env-threading hazard (the main mechanical cost).** Join-R writes into
`MVarEnv`, but many Specialize call sites *discard* the env returned by
`TypeSubst.unify`/`unifyExtend` (e.g. `specializeNode`'s
`Tuple.first (TypeSubst.unify …)` at ≈:2717–2725). A dropped env = a silently
lost taint = a healed-copy hole. Phase 1 therefore includes an **env-threading
audit**: every `unify`/`unifyExtend`/`unifyArgsOnly` call site in Specialize
must thread the returned env back into `state.ctx.mvarEnv` (the `setMVarEnv`
helper at ≈:1248 exists for exactly this). Join-W is deliberately
subst-carried so that routing correctness never depends on this audit being
perfect; the audit only affects Join-R healing coverage.

## Design deltas (all anchors = baseline tree, verified Jul 2026)

### J1. Symmetric join in `unifyMonoMono` (TypeSubst.elm ≈:410–427)

The `MVar/MVar` arm becomes:

```elm
( Mono.MVar mvarId1 _, Mono.MVar mvarId2 _ ) ->
    if same id -> ( subst, env )
    else
        case ( constraintOf mvarId1 env, constraintOf mvarId2 env ) of
            ( Mono.CNumber, Mono.CEcoValue ) ->
                -- number is representative; record class fact
                insertBinding (taintNumber mvarId2 env) mvarId2 m1 subst

            ( Mono.CEcoValue, Mono.CNumber ) ->
                insertBinding (taintNumber mvarId1 env) mvarId1 m2 subst

            _ ->
                insertBinding env mvarId1 m2 subst
```

with `taintNumber : MVarId -> MVarEnv -> MVarEnv` inserting `IO.Number` into
`superVars` (State.elm gains this ~5-line helper next to `freshMVar`). Note
`constraintOf` is used (side table), not the stamped annotations. The
single-var arms `( MVar id _, concrete )` / `( concrete, MVar id _ )` are
unchanged (binding a var to a concrete type is not a class merge).

### J2. Same rule in `unifyHelp`'s `Can.TVar` arm (TypeSubst.elm :286–299)

When binding canonical `TVar mvarId` (a number var per `constraintOf`) to a
mono `MVar otherId CEcoValue`: bind `otherId → MVar mvarId CNumber` and leave
`mvarId` open (the number id is the class root; `applySubst mvarId` yields the
open residual, `applySubst otherId` chains to it; both close Int). All other
shapes unchanged. Audit the analogous re-binding path through
`insertBindingSafe` for the same case.

### J3. `refreshConstraints` + key-time application

New in Monomorphized.elm: `refreshConstraints` maps every `MVar id _` to
`MVar id (constraintOf id env)`... `constraintOf` lives in TypeSubst (imports
State) — to avoid a cycle put `refreshConstraints` in TypeSubst or State.
Apply at the four key-construction sites (all have `state` in scope):

- `enqueueSpec` (Specialize.elm :238–268) — the single global-spec interning
  point; refresh `rawMonoType` before `Registry.getOrCreateSpecId`.
- localMulti instance keys (`getOrCreateLocalInstance` ≈:284–307).
- valueMulti instance keys (`updateValueMultiStack` path).
- the number-multi seed key `intKey = Mono.toComparableMonoType eagerMonoType`
  (≈:3630).

### J4. Re-apply the parent plan's deltas (from the recorded reverted pieces)

Exactly as recorded in the parent plan's post-mortem, with the corrected
pipeline position from attempt #1's second iteration:

- **Flip**: `applySubst` TVar arm (:654–656) and `resolveMonoVarsHelp`
  (:555–557) preserve `MVar id CNumber` instead of returning `MInt`.
- **Closing**: `Mono.resolveNumberType` — now implemented as
  *table-consulting*: `MVar id _ -> if isNumberVar id finalEnv then MInt else
  MVar id CEcoValue` (this subsumes the stamped-annotation check and heals
  stale copies; signature gains the final `MVarEnv`). `MonoTraverse.mapNodeTypes`
  (the total walker: node types, expr types, `CallInfo.evaluatorReturnType`,
  capture ABIs, closure params/captures, `MonoPath`/`MonoDtPath`, deciders,
  ctor shapes) re-derived from the post-mortem record.
  `resolveResidualNumbers` runs **after Prune** in
  `Monomorphize.monomorphizeFromEntryWith` and walks `nodes` +
  `registry.reverseMapping` + `ctorShapes` (Prune recomputes ctorShapes with
  the non-defaulting applySubst, so post-Prune + ctorShapes is mandatory —
  attempt #1's confound). `Monomorphize.monomorphize` must pass the final
  `finalState.ctx.mvarEnv` to the pass.
- **D4 key**: `toComparableMonoType`'s `CNumber` arm keys as `"I"` (identical
  to `MInt`; distinct from the `CEcoValue` sentinel — boxed vs i64 must never
  merge) (:894–914).
- **D5**: `isFullyMonomorphicType` (:≈5683) treats `MVar _ CNumber` as `True`
  (kernel `_Int` suffix fast path); `MVar _ CEcoValue` stays `False`.
- **D6**: PendingCall trigger (:4562) `containsCEcoMVar` → `containsAnyMVar`.
- **Gate predicates CNumber-aware**: `isNumericFixableShape` (:446) and
  `isScalarNumberShape` (:494) gain `MVar _ CNumber -> True` arms
  (`monoTypeMentionsNumeric` :712 already has one).
- `forceCNumberToInt` and its 74 occurrences: **left untouched** (identity,
  harmless) — deletion is the parent plan's Phase 4, out of scope here.

### J5. Env-threading audit (enables Join-R)

Enumerate with
`grep -n "TypeSubst.unify \|TypeSubst.unifyExtend\|TypeSubst.unifyArgsOnly" compiler/src/Compiler/Monomorphize/Specialize.elm`
every call site that discards the returned `MVarEnv` (the `Tuple.first (…)`
pattern). Known major sites: `specializeNode` (:2717–2725), the eager-let
`unifyExtend` enrichments (:3220–3225, :3271, :3505, :3694, :3781–3786),
pending-arg resolutions (:≈4698, :4712), Record/Update per-field arms,
`pushExpectedType`. For each: destructure the pair and thread via
`setMVarEnv` (:≈1248). Estimated ~20–30 mechanical edits. `unifyCallSiteDirect`
already threads env — verify, don't assume.

## Non-goals

- No deletions (demand replay S4, gate tower, `applySubstKeepNumber`, the
  `rhsUsesLocalMulti` bailout, `forceCNumberToInt` call sites) — those are the
  parent plan's Phases 4–5, contingent on this experiment succeeding.
- No codegen/GlobalOpt/artifact changes. The boundary boxing relies on
  existing CGEN_001 behavior; if a failure demands codegen changes, that is an
  **abort criterion**, not scope growth.
- The known-broken `rhsUsesLocalMulti` bailout corner (Float use of a binding
  whose RHS drives localMulti) stays baseline-equivalent: eager-open instance
  closes Int, same as today's eager-Int. Not a regression; not fixed here.

## Implementation order & gates

Per CLAUDE.md test discipline throughout: run each suite ONCE, tee to a file,
grep the file. Baseline before starting: confirm 12,868 unit / 1,547 E2E green.

1. **P1 — plumbing with defaulting still ON** *(zero behavior change intended)*:
   env-threading audit (J5), `taintNumber` + `refreshConstraints` helpers,
   `setMVarEnv` threading. Gate: unit suite byte-identical green; spot E2E
   (`LetNumber`, `IntAdd`, `Combinator`) green.
2. **P2 — join + keys, defaulting still ON**: J1, J2, J3. With eager
   defaulting active, open CNumber barely exists, so this isolates the join
   from the flip. Gate: full unit suite green (the MONO_025
   `ClosureSpecKeyConsistency` "3-var-collision" case is the canary — attempt
   #1 proved a join fixes it; it must pass here *without* the flip).
3. **P3 — the flip + closing + consumers**: J4 in one change-set (the pieces
   are mutually dependent). Gate sequence, in order, stopping at first red:
   a. unit suite (12,868 — includes MONO_024/025, `MonoNumericResolution`,
      `FullyMonomorphicNoCEcoValue` invariant suites);
   b. number E2E families: `LetNumber` (51), `Float` (82), `EmbeddedNothing`
      (9), `UnboxWrapper` (5), `NumberGeneric` (4);
   c. **the 31-test checklist** (below) via targeted `--filter` runs;
   d. full E2E (1,547), after clearing stale `eco-stuff` dirs (no artifact
      format change → `~/.eco` untouched);
   e. self-compile (`cmake --build build --target full`).
4. **P4 — record & document**: on success, update the parent plan (attempt #2
   outcome), `design-recovery.md` §10.2, MONO_002 + new closing-pass invariant
   in `invariants.csv`, and mark the S4/gate machinery as candidates for the
   parent plan's deletion phases. On failure, post-mortem addendum (see
   protocol) and full revert.

## The 31-test verdict checklist (attempt #1's failures)

`AnonymousFunction, CaseCharManyBranch, CaseListCons, CaseMaybe, CaseResult,
CombinatorBSumMap, Combinator, CombinatorWDup, CombinatorTPipe,
CombinatorListString, Composition, EitherType, HigherOrder, IntAdd, IntAbs,
IntMinMax, IntMul, IntNegate, IntPow, IntSub, ListCompoundElements, ListFoldl,
ListFoldr, MultiLocalTailRec, PartialAppChain, PartialApplication, Pipeline,
PolyApplyLambda, TailRecCaseDestruct, TailRecNestedCase, TypeClassConstraint`

Diagnostic hypothesis per cluster, to check off against the mechanism:
- `Int*` (via `Debug.log` CEcoValue boundary) and `Combinator*`/`HigherOrder`/
  `PartialApp*`/`Composition`/`Pipeline`/`PolyApplyLambda` (HOF sharing) →
  should be fixed by **Join-W routing + Join-R healing** (concrete Int
  routing; pre-merge copy healing).
- `Case*`/`EitherType`/`TypeClassConstraint` (custom types) → should be fixed
  by **post-Prune closing incl. ctorShapes** (attempt #1's ordering confound).
- `ListFold*`/`TailRec*` → either/both; these are the informative residuals if
  any remain.

## Success / abort criteria

- **Success**: all gates green through P3e. Then P4.
- **Partial** (some of the 31 fixed, a residual set remains): capture each
  residual's divergence witness (the two disagreeing copies: dump the mono
  graph types via a `TestPipeline.runToMono` repro of the failing shape — NOT
  the bytecode `.mlir`), classify as *no-id copy* (stamped with an
  already-resolved type; Join-R can't reach) vs *erased-key sharing* vs
  *other*. If witnesses are all in one class with a bounded fix ≤ the size of
  this plan, one iteration is allowed; otherwise **abort**.
- **Abort**: revert everything (attempt #1's revert procedure is proven),
  append the witness classification to the parent plan's post-mortem, and
  redirect the effort to solver-reuse Architecture C, where reference
  semantics make this whole class unrepresentable.
- Time-box: this experiment is one focused session including the full E2E
  runs; the revert path must remain a single `git`-less mechanical undo of the
  edit list above (keep the edit list current as work proceeds).

## Risks

| Risk | Mitigation |
|---|---|
| Join-W changes which id lands in stamped copies/keys (representative flip) | The landing id is the *number* id — keys via D4 read it as `"I"` (Int), which is the intended routing; P2 runs the join with defaulting still on to catch any surprise in isolation |
| A missed env-drop site loses a Join-R taint → one healed-copy hole | Join-W keeps routing correct regardless; the hole only re-creates a baseline-class divergence for a pre-merge copy — caught by the 31-test checklist, and the audit grep is re-runnable as a completeness gate |
| Taint leaks into a shared erased-key spec's body (over-unboxing other callers) | Scheme freshening isolates call-site instance vars from spec bodies; key-time `refreshConstraints` routes tainted demands to concrete `"I"` keys — verify with the Combinator cluster, which is exactly this stress |
| `refreshConstraints` cost on hot key paths | O(type size) per key, only at 4 sites; benchmark self-compile at P3e (the parent plan's replay machinery is still present, so no perf offset yet — accept parity) |
| Confound repetition (changing two things again) | P1/P2/P3 staging isolates plumbing, join, and flip; each has its own gate |

## Relationship to other work

- Parent: `plans/number-quiescence-before-defaulting.md` (implements its
  D1/D3–D6 + the join; its deletion phases follow only on success).
- On success, the follow-on order is: parent Phase 4 deletions (S4 replay,
  gate tower, keepNumber fork, the 74 identity `forceCNumberToInt` sites) —
  each gated, per the parent plan.
- On abort: the witness classification becomes direct input to
  `design_docs/monomorphization/solver-reuse-evaluation.md` Architecture C
  (whose zonk-at-readback is precisely Join-R with true reference semantics),
  strengthening its motivation with concrete failure data.
