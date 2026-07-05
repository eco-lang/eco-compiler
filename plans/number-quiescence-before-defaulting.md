# Quiescence Before Defaulting: Resolve `number` at Scope-Close, Substitute Once

## Status: SUPERSEDED — the design goal is now MET via attempt #2 (IMPLEMENTED & GREEN, 2026-07-05)

> **Resolved.** `plans/number-quiescence-symmetric-join-experiment.md` implemented
> this plan's exit-side (preserve CNumber through the fixpoint; single post-Prune
> `resolveResidualNumbers` closing pass) PLUS a **symmetric constraint join** at
> unification, and passes all 12,868 unit + 1,547 E2E tests. The "boxing boundary"
> blocker below was NOT a codegen problem after all: it was a number being ERASED
> to CEcoValue at a `unifyHelp` canonical-vs-mono unification (a deferred number
> arg meeting a boxed parameter slot). The cure is a number-dominates join in
> BOTH unification paths — `unifyMonoMono` (J1) and `unifyHelp` (J2) — recording
> the class fact in the shared side table; J2 was the load-bearing piece. See the
> experiment plan's IMPLEMENTED & GREEN header for the full mechanism. The
> post-mortem below is retained as the diagnostic trail that led there.

> **Implementation attempt outcome.** Batch 1 (D1 flip + D3 closing pass + D4
> key + D5 kernel-ABI + D6 PendingCall + gate-predicate CNumber-awareness) was
> implemented in full and passed **all 12,868 unit tests** and every
> number-centric E2E family (LetNumber 51, Float 82, EmbeddedNothing 9,
> UnboxWrapper 5, NumberGeneric 4). But the **full E2E suite regressed: 31/1547
> failed**, and the failures were reverted. The changes are **not in the tree**;
> it is back at the validated baseline.
>
> **Root cause (single, systemic — not 31 independent bugs).** The flip lets a
> `number` value reach a **polymorphic / boxed (`CEcoValue`) boundary** as an
> open `CNumber` residual, where it is mis-boxed. The canonical repro is
> `Debug.log "x" (10 + 3)`: `Debug.log : String -> a -> a` keeps `a` as
> `CEcoValue` (MONO_009), so the `Int` argument must be *boxed at the call
> boundary*. Under eager defaulting the argument resolved to concrete `MInt`
> early, so codegen saw `MInt`-producer / `CEcoValue`-consumer and inserted the
> box. Under the flip the argument stays `CNumber` and the
> number-var↔CEcoValue-var unification erases it toward `CEcoValue` (or leaves
> it open), so codegen sees a `CEcoValue`-typed slot fed an unboxed `i64` and
> emits `llvm.call` with `'i64' != '!llvm.ptr<1>'` → SIGSEGV. The same boundary
> breaks combinators, higher-order functions, partial application, and
> custom-type cases (`CaseMaybe`, `CaseResult`, `Either`) — every place a
> `number` flows into a `CEcoValue` position.
>
> **Why the closing pass and constraint-join were necessary but not sufficient.**
> A closing pass over `nodes` + `registry.reverseMapping` + `ctorShapes` (the
> last recomputed by Prune via the now-preserving `applySubst`, so it must run
> *after* Prune) is needed and was implemented. A constraint join in
> `unifyMonoMono` (number dominates when a `CNumber` var unifies with a
> `CEcoValue` var) *did* fix a real latent bug — the "3-var-collision"
> `ClosureSpecKeyConsistency` case (MONO_025), where a `number` unified with a
> fresh callee scheme var lost its constraint (masked by eager defaulting). But
> the join over-corrected other cases and, more importantly, neither addresses
> the codegen-side boxing decision: the boundary logic that decides "box this
> `MInt` into an `eco.value`" does not treat an open `CNumber` (or a number
> erased to `CEcoValue`) as "a concrete `Int` that must be boxed here."
>
> **What the full implementation actually requires (revised scope).** The plan
> underestimated the blast radius. In addition to D1–D8 it needs: (a) a
> **boxing-boundary rule** — everywhere a value crosses into a `CEcoValue`
> position (kernel ABIs incl. `Debug.log`, polymorphic parameters, heap fields,
> closure captures), an open `CNumber` must be treated as a concrete `Int` and
> boxed, never erased to `CEcoValue`; (b) an **audit of every `containsAnyMVar`
> guard in Specialize** (~15 sites + the "trust the value" fallbacks), whose
> behavior changes once `CNumber` is preserved; (c) a principled resolution of
> the **constraint-join direction** (`CNumber` must dominate `CEcoValue` at
> unification, but without over-unboxing genuinely-boxed positions). This is a
> codegen-spanning, multi-session effort — most naturally done as part of the
> **solver-reuse Architecture C** migration, where zonk-at-readback and honest
> boxing at ABI boundaries are unified, rather than retrofitted onto the
> `Dict`-substitution engine.
>
> **Verified-correct, reusable pieces (removed from the tree but recorded here).**
> The `MonoTraverse.mapNodeTypes` total type-mapper (mirrors
> `Analysis.collectCustomTypesFrom*` incl. `CallInfo.evaluatorReturnType` /
> `captureAbi`, `ClosureInfo.captureAbi`, `MonoDtPath`), `Mono.resolveNumberType`,
> the post-Prune closing hook, and the `unifyMonoMono` CNumber-join are all
> individually sound and were validated against the unit suite; re-derive them
> from git history / this note for a second attempt.

## Status: Planning (v2 — refined against code, all anchors verified Jul 2026)

## Goal

Remove the monomorphizer's **eager `number → Int` defaulting** and the stack of
machinery built to detect and undo it, replacing it with **quiescence before
defaulting**: `CNumber` survives as a residual through the entire specialization
fixpoint, resolves to `Float` only by unification with a real `MFloat` demand,
is *read* as `Int` at the few mid-fixpoint points that consume a resolved
number (all of which sit at local quiescence for that variable), and is
*substituted* to `MInt` exactly once — in a single closing pass over the
finished `MonoGraph`, after the worklist drains and before Prune/GlobalOpt.

Today `CNumber → MInt` fires at exactly two places inside the substitution
engine — `TypeSubst.applySubst`'s unbound-`TVar` arm (`TypeSubst.elm:654-656`)
and `resolveMonoVarsHelp`'s unbound-`MVar` arm (`:555-557`) — which means it
fires at **every** substitution application, continuously during the
demand-driven fixpoint, long before a let-generalized `number`'s Float demand
(which lives on a *later*-specialized use site) can be observed. Every band-aid
in the number system exists to outrun that early default: `let n = 1 in
(n, n * 1.5)` commits `n` to Int producer-first, then miscompiles `n * 1.5` as
`mul_Float (f64, i64)`.

The payoff (per `design_docs/monomorphization/design-recovery.md` §5–6, §10.2):
the demand-replay analysis (S4), the number-multi gate tower, the
`applySubst`/`applySubstKeepNumber` fork, and the 73 mid-fixpoint
`forceCNumberToInt` identity calls become dead and are deleted; `number`
multi-specialization stops being a bespoke gated mechanism and becomes the
ordinary "polymorphic let" case.

## Background

Read first: `design-recovery.md` §4 (the two hostile features), §5 (the
accretion strata), §6 (the number saga), §10.2 (the target). This plan
implements §10.2. Constraint *provenance* (entry side) is already fixed by
`plans/solver-roots-super-constraint-export.md`; this plan fixes the *exit*
side (when the constraint is discharged).

**Why eager defaulting is wrong.** The pass is a least fixpoint over a demand
relation; a variable's type is fully known only at *quiescence*. Defaulting is
a *closing operator* — sound only once no further demand can arrive. Applying
it during iteration commits to `Int` before backward-flowing Float demand
(let-generalization's signature) is seen. The fossil proving the operator
migrated into `applySubst` is `forceCNumberToInt`
(`AST/Monomorphized.elm:267-272`) — once the real defaulting function, now the
identity, its doc block still describing the intended semantics ("when we have
an ambiguous `number` that has not been resolved to Float by constraints, we
default it to Int"). It is called at **73** sites in `Specialize.elm` (the
comment's "57 call sites" is stale).

**The machinery that fights the early default** (verified anchors; all removed
or subsumed by this plan):

- **The two-operator fork**: `applySubst` defaults (`TypeSubst.elm:637`); its
  structural clone `applySubstKeepNumber` (`:955-1123`, with private
  `resolveMonoVarsKeepNumber` / `applySubstLambdaChainKeepNumber`) preserves
  `CNumber`. Non-replay callers: `Specialize.elm:4509, :4540, :4595`.
  Correctness depends on picking the right operator per site.
- **Demand replay (S4)**: `callArgDemands` (`:834`), `collectNumericDemands`
  (`:870`), `collectNumericDemandsDef` (`:926`), `demandedNumericUseType`
  (`:959`) — walk the *un-specialized* body of a number binding and replay
  call-site unification (with keep-number arg types, `:842`) to predict Float
  demand before committing. A shadow analysis simulating "look at the uses
  first".
- **The number-multi gate** (`Specialize.elm:3569`): `hasUnresolvedNumberVar
  && isNumericFixableShape && (isNumericDataRhs || (isScalarNumberShape &&
  demandedNumericUseType ≠ Nothing))` decides eager-Int vs deferred
  re-specialization; predicates at `:430, :446, :494, :568`. A post-hoc
  `rhsUsesLocalMulti` bailout (`:3597-3600`, via `localMultiInstanceCount`
  `:645`) makes number-multi and `localMulti` mutually exclusive per binding.
- **Guard holes**: the `Destruct` concreteness guard (`:3839`) carves a
  `floatDemand == Nothing` exception (`floatDemand` computed at `:3832` via
  demand replay; leaf driven from it at `:3887`); `pushExpectedType` pushes
  if/case result types into branch substs so a `number` branch doesn't default.

## The correctness model

Definitions: a number var is **open** if the substitution has no binding for
it (its `MonoType` occurrence is `MVar id CNumber`); it is **bound** when
unification bound it (to `MFloat`, `MInt`, or another var). A var is at
**local quiescence** at a program point if no unification that could still
bind it will run after that point.

**Lemma (Float manifests as MFloat).** Under D1, a number var becomes `MFloat`
*only* via unification with a concrete Float demand, and nothing ever rewrites
an open var to `MFloat` spontaneously. Therefore at any locally-quiescent
point, *open ⇒ eventually Int*. This is what licenses reading open `CNumber`
as `Int` mid-fixpoint and substituting `MInt` at the end.

**The consumers of resolved number types, enumerated:**

1. **Spec keys** (`toComparableMonoType`, `AST/Monomorphized.elm:894-914`).
   Keys are computed at call sites (arguments concrete ⇒ scheme number vars
   bound) or at let-instance emission (after the body was specialized ⇒ the
   binding's vars are at scope-close). By the lemma, an open var in a key
   means Int, so keys may canonicalize open `CNumber` to a sentinel (D4).
   Merging is per-`Global` (the key includes the Global), so the sentinel only
   merges same-global, all-Int-destined instantiations — which is the point.
2. **Kernel-ABI suffix selection** (`deriveKernelAbiType` `:5749` gated by
   `isFullyMonomorphicType` `:5683`). Only the *mono-time* fully-monomorphic
   check needs to change (D5): treat `MVar _ CNumber` as monomorphic-Int so
   the `_Int` fast path is kept. The backend's per-instance symbol selection
   runs at codegen, **after** the closing pass, and needs no change — it sees
   `MInt`.
3. **Layouts / unboxing bitmaps** are computed at codegen (Axiom 3), after
   closing. Never see `CNumber`.
4. **GlobalOpt** runs after the closing pass. Never sees `CNumber`.

**The one real hazard: emitted-before-bound.** A `MonoType` containing an open
var is *baked into an emitted `MonoExpr`*; the var is bound (to `MFloat`)
*later within the same work item*; the emitted type is now stale, and the
closing pass would wrongly stamp it `MInt`. This is not hypothetical — it is
today's `f (g 1) 2.5` / "generic-call RHS" fragility wearing a new face. Three
defenses, layered:

- **Deferral already covers most of it, and D6 widens the last trigger.**
  Arguments whose types still contain MVars are deferred until the callee's
  params are known (`ProcessedArg`, `:59-66`): `PendingGlobal`'s trigger
  already uses the keep-number substitution (`:4595` + `containsAnyMVar`), so
  number-containing globals already defer; `PendingCall`'s trigger is
  `containsCEcoMVar` (`:4562`) and must widen to `containsAnyMVar` so a nested
  call with an open-number result defers too.
- **Let-instance emission re-derives types from the refined subst.** The
  valueMulti machinery already re-derives each instance's type from its
  refined substitution at pop (design decision D6/D7 in its comments); this
  plan keeps that mechanic (D7 below), so binding-side emissions are
  refreshed, not stale.
- **The closing pass makes any residual miss deterministic and diagnosable**:
  a missed Float propagation closes to Int — exactly today's failure mode, not
  a new one — and Phase-2's A/B testing plus the number E2E suite is the net.
  A debug-mode assertion (P0's checker) can be extended to flag "open CNumber
  bound elsewhere in the same graph" if a concrete escape is ever found.

## Design

### D1. `applySubst` preserves `CNumber`; delete the fork

- `applySubst` unbound-`TVar` arm (`TypeSubst.elm:654-656`): return
  `Mono.MVar mvarId constraint` for `CNumber`, exactly as the `CEcoValue` arm
  (`:659`) does.
- `resolveMonoVarsHelp` unbound-`MVar` arm (`:555-557`): return
  `( False, monoType )` for `CNumber`, as the `CEcoValue` arm (`:560`) does.
- These are the **only two** defaulting sites in the engine (verified; the
  `:680` `MInt` is the concrete `TType "Int"` mapping, not defaulting).
  `canTypeToMonoType` **is** `applySubst` (`:1129`, an alias), so it inherits
  the change; its callers (entry-point conversion `Monomorphize.elm:610`,
  `Analysis` ctor shapes — which run post-closing under D3's ordering —
  and `KernelAbi`) are covered by the consumer analysis above.
- Delete `applySubstKeepNumber`, `resolveMonoVarsKeepNumber`,
  `applySubstLambdaChainKeepNumber` (`:955-1123`) and the exposing entries;
  repoint callers `:4509, :4540, :4595` to `applySubst` (mechanical: keepNumber
  returns a bare `MonoType`, `applySubst` returns `( MonoType, MVarEnv )` —
  take `Tuple.first`; no fresh allocation happens on these paths). The replay
  caller `:842` is deleted with S4 (D8).
- `constraintOf` (`:54`) is untouched — it reports the constraint; only the
  defaulting downstream of it is removed.

### D2. `forceCNumberToInt` becomes the closing operator; no mid-fixpoint calls

Restore `forceCNumberToInt` (`AST/Monomorphized.elm:267`) to its documented
semantics: recurse structurally through the `MonoType`, mapping
`MVar _ CNumber → MInt` and leaving everything else (including
`MVar _ CEcoValue`) untouched. Delete all 73 call sites in `Specialize.elm`
(they are identity today, so deletion is behavior-neutral in any phase) —
including the one in `enqueueSpec` (`:246`): the registry now interns raw,
possibly-open types; D4 gives them stable keys and D3 closes the stored types.
After this plan the function has exactly one caller: the closing pass.

### D3. `resolveResidualNumbers` — the single closing pass

**Pipeline position** (`Monomorphize.elm`, `monomorphizeFromEntryWith`
`:182-232`): `processWorklistPure` (`:224`) → `assembleRawGraphFrom` (`:227`)
→ **`resolveResidualNumbers`** → `Prune.pruneUnreachableSpecs` (`:230`). The
ordering is load-bearing, not a preference: Prune **recomputes `ctorShapes`
from the pruned nodes** (`Prune.elm:98, :159`), so closing must run first for
ctor shapes to be computed from closed types; `assembleRawGraphFrom` sets
`ctorShapes = Dict.empty` (`Monomorphize.elm:369`), so the raw graph carries
none to close.

**What it must walk** (and what it provably need not):

- Every `MonoNode` in `graph.nodes` — all embedded `MonoType`s: node type,
  `MonoTailFunc` params, `ClosureInfo` (params, captures, type), every
  `MonoExpr` type field, `MonoDef`/`MonoTailDef` types, `MonoDestruct` path
  types, `MonoCase` `Decider`/`Choice`/`MonoDtPath` types.
- `registry.reverseMapping : Array (Maybe ( Global, MonoType, Maybe LambdaId ))`
  (`Registry.elm:68`) — the stored spec types must be closed with the same
  operator or MONO_017 (registry type = node type) breaks. (`registry.mapping`
  is already dropped at assembly, `Monomorphize.elm:367`.)
- **Not** `ports` — `PortRegistration` (`AST/Monomorphized.elm:460-465`)
  carries no `MonoType`. **Not** `ctorShapes` (empty pre-Prune, recomputed
  post-closing). **Not** `callEdges`/BitSets (ints).

**Mechanism**: `MonoTraverse` exposes only `traverseExpr`/`foldExpr`
(expression-level; they do not visit types embedded in paths/deciders/closure
info). Add a total type-mapper — `mapNodeTypes : (MonoType -> MonoType) ->
MonoNode -> MonoNode` plus the `MonoExpr`/`Decider`/path walkers — to
`MonoTraverse`. **Mirror `Analysis.collectCustomTypesFrom{MonoType, Expr,
Path, Decider, DtPath}`** (`Analysis.elm`), which already enumerates every
type position in the IR and is exercised by ctor-shape computation; matching
its structure arm-for-arm gives a coverage argument by construction
(~150–250 lines, mechanical).

### D4. Spec-key canonicalization: a distinct sentinel for open `CNumber`

In `toComparableMonoType`'s `MVar` arm (`AST/Monomorphized.elm:894-914`),
replace the keep-real-id `CNumber` case with a fixed sentinel fragment
`("number" :: "\u{0000}" :: "0" :: "V" :: acc)`, mirroring the existing
`CEcoValue` fragment `("ecovalue" :: …)`.

**It must be a *different* sentinel from `CEcoValue`, not the same one.** An
open `CNumber` position closes to `MInt` (unboxed `i64`); an open `CEcoValue`
position stays boxed `!eco.value`. Merging a number-open and an ecovalue-open
instantiation of the same global into one SpecId would give one specialization
two incompatible ABIs. Distinct sentinels keep the merge classes ABI-uniform:
all number-open (⇒ Int) instantiations of a global share one spec — which is
precisely the merge the number-multi machinery currently sweats to achieve —
while Float instantiations differ as bound `MFloat`, and erased ones as the
ecovalue sentinel. Multiple distinct open number vars in one key all read
"Int" and need no id-distinction (the lemma). Update the `:904` comment: the
old text ("if it leaks, distinct IDs prevent incorrect merging of Int vs Float
specializations") described a defense against Float-as-open-CNumber, which the
lemma makes unrepresentable.

### D5. Mid-fixpoint consumers read open `CNumber` as Int

- `isFullyMonomorphicType` (`Specialize.elm:5683`): add
  `MVar _ CNumber -> True` (open ⇒ Int ⇒ monomorphic for ABI purposes), so
  `deriveKernelAbiType` (`:5749`) keeps the concrete `_Int`/`_Float` suffix
  fast path for `suffixSelectingKernels`. `MVar _ CEcoValue` stays `False`.
- No backend change: `kernelInstanceSymbol` selection happens at codegen,
  post-closing, on `MInt`.
- Anything not enumerated in "consumers" that turns out to inspect a number
  type mid-fixpoint shows up as a Phase-2 test failure with a visible
  `MVar _ CNumber` in hand — loud, unlike today's silent early-Int.

### D6. Widen the `PendingCall` deferral trigger

`Specialize.elm:4562`: `containsCEcoMVar` → `containsAnyMVar`, so a nested
call whose result contains an open number var is deferred until the outer
callee's parameter type can bind it (the `f (g 1) 2.5` shape). This is the
only trigger that needs widening: `PendingGlobal` already defers on
`containsAnyMVar` over the keep-number type (`:4595-4598`), and
`PendingAccessor`/`LocalFunArg`/`PendingNumberValue` are shape-triggered.
After this, `containsCEcoMVar` has no callers in `Specialize.elm` — delete it
from `Monomorphized.elm` (`:328-363`) if no other user remains.

### D7. Uniform let deferral — generalize number-multi, don't reorder

Replace the number-multi gate condition (`:3569`) with the uniform predicate:

> defer iff `Mono.containsAnyMVar (applySubstFV state subst defCanType)` —
> i.e. the binding is still polymorphic under the (now non-defaulting)
> substitution.

`hasUnresolvedNumberVar`, `isNumericFixableShape`, `isScalarNumberShape`,
`isNumericDataRhs`, and the `demandedNumericUseType` conjunct all fall out of
the gate: they existed to predict, from shape and provenance, whether deferral
was *worth the risk* given that not deferring meant a possibly-wrong eager
Int. Under D1 the eager path emits *open* types (closed to Int only at the
end), so admitting every unresolved binding is safe by the lemma.

**Deliberately keep the existing eager-specialize → seed-instance →
body-specialize → emit-instances-at-pop structure** (the number-multi/
valueMulti mechanic) rather than switching to a full body-first reorder. Full
deferral of the RHS was tried in June 2026 and abandoned because it scrambled
`localMulti` instance recording inside the RHS (the reason number-multi is a
hybrid — see the gate's comments). With residual `CNumber`, the eager-first
structure loses its downside: the eagerly-emitted instance is open, not
Int-committed; body uses that demand Float produce additional instances keyed
by `MFloat` (now via the ordinary D4 keys); instance types are re-derived from
the refined subst at pop (existing valueMulti mechanics). The full reorder /
stack unification remains §10.3 follow-on work.

**Keep the `rhsUsesLocalMulti` bailout (`:3597-3600`) in this phase.** When it
fires, the binding falls back to the plain eager path — which now emits open
types that close to Int, i.e. *exactly today's semantics* in that corner, no
regression. Removing the bailout (extending Float-instance support to bindings
whose RHS records localMulti instances) is a candidate in D8's verify-inert
list, gated on the number E2E suite.

### D8. Deletions

**Certain** (dead by construction after D1–D7):

- `applySubstKeepNumber` + private helpers (D1).
- Demand replay: `callArgDemands` (`:834`), `collectNumericDemands` (`:870`),
  `collectNumericDemandsDef` (`:926`), `demandedNumericUseType` (`:959`), and
  the `floatDemand` computation + hole in the `Destruct` guard
  (`:3832-3839, :3887` — the guard keeps its CEcoValue/layout half; only the
  number-demand carve-out goes).
- Gate predicates: `hasUnresolvedNumberVar` (`:430`), `isNumericFixableShape`
  (`:446`), `isScalarNumberShape` (`:494`), `isNumericDataRhs` (`:568`) — and
  their uses at `:420` (`shouldUseValueMulti`) and `:658`
  (`isNumberMultiTarget`) replaced per D7's uniform predicate.
- The 73 `forceCNumberToInt` mid-fixpoint calls (D2).

**Verify-inert** (expected dead; delete only with grep + suite evidence, one
per commit): `PendingNumberValue` (`:65, :4508, :4539, :4771`) and
`resolveNumberMultiVarRef` (`:777`) / `recordNumberInstanceAgainstShape`
(`:746`) — these are the number-instance recording hooks; under D7 the generic
instance mechanics may subsume them, but they interlock with valueMulti
destructor tagging and must be proven redundant, not assumed. Likewise
`pushExpectedType` ("Fix 2") and the `rhsUsesLocalMulti` bailout.

## Non-goals

- **Not** the solver-reuse engine swap
  (`design_docs/monomorphization/solver-reuse-evaluation.md`, Architecture C).
  Union-find makes quiescence native and zonk-at-readback *is* this plan's
  closing pass; this plan reaches the same defaulting placement inside the
  existing `Dict`-substitution engine, de-risking that larger change.
- **Not** unifying `localMulti`/`valueMulti` into one tagged stack or the full
  body-first reorder (`design-recovery.md` §10.3) — D7 deliberately keeps the
  proven eager-first structure.
- **Not** the `CEcoValue` strata (S5 value-derived container types, the
  CEcoValue half of the `Destruct` guard) — different root cause.
- **Not** `Mono.Constraint`, artifact formats, GlobalOpt, or codegen.

## Expected behavior changes

Behavior-preserving where the eager default was correct; strictly better where
it fired early (the `mul_Float (f64, i64)` / boxed-silent-miscompile family).
Concretely observable diffs:

- **SpecId numbering and specialization counts change** (D4 merges all-Int
  instantiations that today get distinct CNumber-id keys; D7 admits bindings
  the gate previously rejected). Runtime E2E outputs are SpecId-independent —
  they are the oracle. Any *runtime* output diff is a bug or a fixed
  miscompile; investigate individually.
- Kernel calls on open-number paths keep the `_Int` suffix fast path (D5); no
  boxing regression expected.

## Implementation phases

Each phase compiles, and the gates are: elm-tests (once, tee to
`/tmp/test_output.txt`, grep — per CLAUDE.md), then number-filtered E2E, then
full E2E; self-compile via `--target full` at P2 and later.

### Phase 0 — Closing pass + totality checker (no behavior change)

Implement `MonoTraverse.mapNodeTypes` (D3's walker) and a `foldExpr`-style
`findResidualCNumber : MonoGraph -> List (SpecId, MonoType)` checker. Wire
`resolveResidualNumbers` into the pipeline between assemble and Prune with the
**real** rewriting operator, and add a TestLogic invariant test (natural home:
alongside `TestLogic/Generate/MonoNumericResolution*`) asserting the checker
finds nothing *after* the pass. Because eager defaulting is still active, the
pass must find nothing *before* it either — assert that too in the test
pipeline for this phase only: it validates walker totality as a no-op on real
programs. Gate: suites green, zero rewrites observed.

### Phase 1 — Key sentinel (near-no-op while defaulting is eager)

Apply D4 (distinct `number` sentinel in `toComparableMonoType`). With eager
defaulting still on, almost no `CNumber` reaches keys, so this isolates the
key-identity change from the flip. Gate: suites green.

### Phase 2 — The flip

Apply D1 (preserve `CNumber`; delete the keepNumber fork), D5
(`isFullyMonomorphicType` reads open as Int), D6 (`PendingCall` trigger
widening), and D2 (delete the 73 identity calls — mechanical, any time in this
phase). Drop Phase-0's "nothing before the pass" assertion (residuals are now
expected pre-pass); keep the "nothing after" invariant permanently. The S4
replay and gate tower still exist and still run — they are now defending
against a default that no longer fires, and are expected to be inert (replay
now *observes* non-defaulted types, so `demandedNumericUseType` returns what
unification already knows). **This is the high-risk phase**; the number E2E
families (`LetNumber*`, `Float*`, `EmbeddedNothing*`, `UnboxWrapper*`,
`NumberGeneric*`) are the critical oracle, then full E2E + self-compile.
Revert point: Phase-1 SHA.

### Phase 3 — Uniform let deferral

Apply D7: replace the `:3569` gate with the `containsAnyMVar` predicate; keep
the `rhsUsesLocalMulti` bailout. Add the unit tests (Testing below) proving
`let n = 1 in (n, n * 1.5)` yields Int and Float instances through the
now-generic path and `let n = 1 in n + n` yields a single shared spec. Gate:
number E2E, esp. `LetNumberBoxedSilentMiscompileTest`,
`LetNumberDestructureTest`, `LetNumberCaseTuple3Test` (the case/generic-call
RHS shapes the old gate rejected).

### Phase 4 — Deletions

D8's **certain** list first (replay, gate predicates, guard hole), one logical
group per commit, suite-gated. Then the **verify-inert** candidates
individually: for each, grep call sites, remove, run the number E2E family; if
anything fails, the candidate was load-bearing — restore and document why in
the code. Gate after the batch:
`grep -rn "hasUnresolvedNumberVar\|isNumericDataRhs\|collectNumericDemands\|applySubstKeepNumber" compiler/src/Compiler/Monomorphize/`
returns nothing.

### Phase 5 — Invariants & docs

- `MONO_002` reword: no `MVar _ CNumber` may survive `resolveResidualNumbers`
  (checked by the P0 invariant test); transient `CNumber` in `MonoType`s
  *during* specialization is legal.
- New invariant (next free MONO id): `resolveResidualNumbers`, running between
  graph assembly and Prune, is the **single** CNumber→MInt defaulting point in
  the compiler; `applySubst` and all per-site code preserve `CNumber`; verified
  by `findResidualCNumber` in TestLogic.
- `design-recovery.md`: §6 "Defaulting during iteration" → *(fixed)*; §10.2 →
  *(done)*; note which S-strata fell.
- Theory doc (`pass_monomorphization_theory.md`): update the
  `forceCNumberToInt` section — it is now the closing pass's operator, not a
  per-site default.
- Mark superseded (header note each):
  `plans/let-number-demand-driven-specialization.md`,
  `plans/let-number-unify-value-multi.md`,
  `plans/let-number-consumer-producer-threading.md`, and the
  number/`PendingNumberValue` portions of
  `plans/intra-monomorphization-deferrals.md`.

## Testing

- **Primary oracle: runtime E2E** (SpecId-independent by nature — no golden
  MonoGraph comparison needed). Per CLAUDE.md discipline, run once and grep the
  tee'd file: `TEST_FILTER=LetNumber`, then the `Float*`/`EmbeddedNothing*`/
  `UnboxWrapper*`/`NumberGeneric*` families, then unfiltered `test/test`, then
  `--target full` (self-compile).
- **Invariant tests** (TestLogic): P0's `findResidualCNumber` post-pass check
  (permanent); keep `MonoNumericResolution*`, `MonoGraphIntegrity*`,
  `FullyMonomorphicNoCEcoValue*`, `MonoVarGlobalArityConsistency*` green —
  they encode MONO_002/011/021/027 and will catch consumer misses.
- **New unit tests** (via `TestLogic/TestPipeline.expectMonomorphization`
  or `monomorphizeAny`):
  1. `let n = 1 in (n, n * 1.5)` — two instances (Int, Float), no
     number-multi-specific machinery consulted (post-P4: machinery gone).
  2. `let n = 1 in n + n` — one instance, Int, one SpecId.
  3. A case/generic-call RHS shape (`let n = if b then 1 else 2 in n * 1.5`)
     — Float instance produced (the class the old `isNumericDataRhs` gate
     rejected).
  4. Key identity: two all-Int-destined instantiations of one polymorphic
     global share a SpecId; an Int and a Float instantiation do not; a
     number-open and an ecovalue-open position do not collide (D4 sentinel
     distinctness).
- **Perf**: self-compile wall time and the elm-aws-codegen stress input per
  phase (replay deletion should net positive; residual-MVar traffic is the
  counter-pressure).

## Risks

| Risk | Assessment / mitigation |
|---|---|
| Emitted-before-bound: an open var baked into an emitted MonoExpr is bound to Float later in the same work item; closing stamps the stale copy Int | The named hazard of the whole design (see correctness model). Defenses: D6 trigger widening, instance-type re-derivation at pop (existing mechanics, kept by D7), and the fact that a miss reproduces *today's* failure mode rather than a new one. Number E2E is the net; if a concrete escape is found, extend deferral for that shape rather than re-adding defaulting. |
| Same-key, different-history collisions via the D4 sentinel | Bounded: sentinel merges are per-Global; all merged instantiations are open ⇒ Int (lemma), so ABI-uniform. Distinct-from-CEcoValue sentinel prevents boxed/i64 collisions. Unit test 4 pins this. |
| An unenumerated mid-fixpoint consumer inspects number types | Fails loud (visible `MVar _ CNumber` in a crash or invariant test) instead of today's silent early-Int; fix by adding it to D5's read-as-Int set with the local-quiescence argument, or defer it. |
| Phase-2 flip breadth | Isolated by P0/P1 landing the closing pass and keys first; the flip itself is two arms in TypeSubst + one predicate + one trigger; revert point is the P1 SHA. |
| June-2026 ordering scramble returns via deferral changes | Avoided by design: D7 keeps the eager-first structure and the `rhsUsesLocalMulti` bailout; the full reorder is explicitly out of scope. |
| Perf regression from longer-lived MVars | Replay deletion removes a per-number-binding full-body walk; gate tower removal cuts per-let predicate evaluation. Benchmark per phase. |

## Relationship to other work

- **Entry side (done)**: `plans/solver-roots-super-constraint-export.md`
  supplies loss-free `CNumber` provenance. Together with this plan, both
  halves of the number root cause (`design-recovery.md` §1) are closed.
- **Solver reuse** (`solver-reuse-evaluation.md`, Architecture C): the
  union-find engine realizes this model natively (order-independent
  unification = quiescence for free; zonk = `resolveResidualNumbers`). Doing
  this plan first shrinks and de-risks that migration: after it, the engine
  swap changes *how* types are computed but no longer *when* numbers default.
- **§10.3 follow-on**: with defaulting gone, the remaining `Pending` variants
  and the `localMulti`/`valueMulti` stacks are one "defer until consumer type
  known" concept; unifying them (and the full body-first reorder) is the next
  consolidation plan.
