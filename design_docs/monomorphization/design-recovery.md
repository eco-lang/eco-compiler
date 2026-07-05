# Monomorphization: Recovered Design

*A design-archaeology report. Sources: full reads of all 12 modules under
`compiler/src/Compiler/Monomorphize/` plus `AST/Monomorphized.elm` (~13,300 lines),
`design_docs/theory/pass_monomorphization_theory.md`, `design_docs/invariants.csv`
(MONO_001–027), the Roc-derived docs in this directory, and the full git history
(221 commits, 2025-12-05 → 2026-07-02, recovered via the public GitHub mirror).*

---

## 1. Executive summary

The pass was born (Dec 2025) as a **Roc-style lambda-set specializer**, designed
up front in a 1,724-line plan document. What actually survives of that design is
smaller and better: a **demand-driven worklist fixpoint over interned
`(Global, MonoType)` specialization keys**. Lambda sets themselves are gone —
their skeleton (`Maybe LambdaId` in `SpecKey`) is still threaded through every
signature but every call site passes `Nothing`.

The pass's real identity was not designed; it **converged by subtraction**.
Three successive extractions narrowed it to "pure type specialization":
layout computation moved to codegen (Jan–Feb 2026), staging/uncurrying moved to
GlobalOpt (Feb 2026, GOPT_016), kernel ABI policy moved to per-instance backend
derivation (May 2026). What remained is a clean core — perhaps 2,000 of
Specialize.elm's 5,973 lines — wrapped in roughly an equal volume of accretion.

The accretion is not random. Essentially **all of it is one problem**: the
engine was built to flow type demand *forward* (producer-first, eager), but two
Elm features make demand flow *backward* — the `number` class under
let-generalization, and row-polymorphic records. Every major patch stratum is a
partial retrofit of backward (consumer→producer) demand flow, reinvented per
syntactic position instead of generalized. Section 5 names five such strata;
section 6 traces the worst case (the `number` saga: five successive resolution
models in seven months).

The single deepest root cause is that **the `number` constraint enters the pass
through a lossy side channel**: it is re-derived from type-variable *name
prefixes* (`constraintFromName` in AssignMVarIds) rather than exported from the
solver, and it is *defaulted to Int eagerly inside `applySubst`* — i.e. during
the fixpoint iteration rather than at quiescence. Nearly every band-aid in the
file exists to outrun that early default.

The pass has been stable since 2026-06-12 (Specialize.elm frozen at 5,973
lines), so this is a good moment to consolidate. Section 10 restates the ideal
design the code is visibly converging toward; section 11 lists concrete
simplifications, including one **latent live bug** found during this analysis
(§9.1).

---

## 2. Origins: what was imported, what survived, what died

`design_docs/monomorphization/README.md` and `specialization.md/.rs` are
documentation of **Roc's `roc_mono` crate** — the imported inspiration. The
birth commit (`a72acb9`, 2025-12-05, "Add monomorphization pass driven by
lambda sets") shipped a single 1,452-line module and a plan document whose
headings pre-identified every future fix cluster (code bloat, recursive types,
mutual recursion, higher-order functions, partial application, kernels).

| Roc concept | Fate in Eco |
|---|---|
| Demand-driven worklist, seeded from entry points | **Survived intact** — the spine (`processWorklistPure`, `enqueueSpec`) |
| `(Symbol, ProcLayout)` specialization keys | **Survived, improved** — `SpecKey(Global, MonoType, Maybe LambdaId)` interned to dense `SpecId` ints; the graph is SpecId-indexed and closed |
| Specialization stack / suspend-on-recursion | **Simplified** — an `inProgress` BitSet; a recursive re-request is dropped (its SpecId already exists, so references stay valid) |
| Lambda sets (closure unions, per-lambda specialization) | **Dead** — `Maybe LambdaId` threaded but always `Nothing`; `ClosureKind` has one constructor whose doc describes a deleted sibling; closure dispatch went the GlobalOpt ABI-cloning route with `CallGenericApply` fallback |
| Closure conversion / lambda lifting into top-level procs | **Not adopted** — closures stay inline (`MonoClosure` inside parent nodes); lifting/staging is GlobalOpt's job |
| Pattern-match decision trees compiled here | **Not adopted** — decision trees arrive already built (TypedOptimized); the pass only *types* them (`specializeDecider`/`specializePath`) |
| Layout computation in mono | **Adopted then reverted** — ctor layouts moved in (`3be8513`, Jan 14) and back out thirteen days later (`977beae`/`f0e60e9`): "field ordering and unboxing bitmaps deferred to where they belong: the MLIR backend." IR now carries `CtorShape` (name/tag/fieldTypes), not layouts |
| Typestate snapshot/rollback | **Not adopted** — substitutions are pure `Dict`s; failure is silent no-op unification instead of rollback |

A second imported-then-corrected idea: the pass originally owned uncurrying and
calling conventions. The Feb 5–6 2026 consolidation ("**Restrict
monomorphization to pure type specialization**") extracted all of it to
GlobalOpt and shrank Specialize.elm by ~570 lines. This boundary — mono is
**staging-agnostic**, preserving curried `MFunction [a] (MFunction [b] c)`
nesting exactly — is now one of the pass's firmest contracts (GOPT_001/016).

---

## 3. The essential theory

Stripped of accretion, the pass computes a **least fixpoint of a demand
relation**, with four axioms.

**Axiom 1 — Demand fixpoint.** A *demand* is a pair `(Global, MonoType)`.
Seed: `main` at its concrete type (plus synthetic roots: the flags decoder,
port decoders). A demand is discharged by:

1. looking up the definition's annotation scheme,
2. instantiating it with **fresh** MVarIds (per-instantiation freshening),
3. unifying scheme against demanded type → a `Substitution : Dict MVarId MonoType`,
4. rewriting the body under that substitution (`specializeExpr`),
5. during which every global reference computes its own instantiated MonoType
   and **emits a new demand** (`enqueueSpec`).

Termination: demands are interned in the Registry keyed by
`toComparableMonoType`; the `scheduled` BitSet ensures each is discharged once;
`inProgress` breaks recursion. The output graph is **closed**: every
`MonoVarGlobal` carries a `SpecId` that indexes an existing node (MONO_005/011).

**Axiom 2 — Specialization identity is type identity.** Two uses share code
iff their demanded MonoTypes are equal *up to CEcoValue-erasure*. This is
implemented in the comparable key: every `MVar _ CEcoValue` normalizes to one
sentinel (so fresh phantom vars don't split specializations), while
`MVar _ CNumber` keeps its real id (so a leaked unresolved number can never
merge an Int and a Float specialization — a deliberately defensive asymmetry,
Monomorphized.elm:903–908).

**Axiom 3 — Pure type specialization.** The pass decides *what code exists at
which types* and nothing else. Not layout (codegen owns unboxing bitmaps), not
staging/arity (GlobalOpt owns argument grouping; `CallInfo` and
`ClosureKind`/`CaptureABI` slots are emitted as placeholders for GlobalOpt to
overwrite), not kernel calling conventions (kernels are unspecialized
`MonoVarKernel` *leaves* with ABIs derived per-instance in the backend).

**Axiom 4 — Bounded residual polymorphism.** Exactly two constraints survive
mid-pass, forming a two-point obligation lattice:

- `CEcoValue` — *erasable*: layout-independent, may legally survive to codegen
  as boxed `!eco.value` (MONO_003), but must not survive in reachable
  user-function parameter/result positions (MONO_020/021/024 — an invariant
  strengthened three times as bugs were found).
- `CNumber` — *must be discharged*: resolved to `MInt`/`MFloat` before the
  codegen boundary; any survivor is a compiler bug (MONO_002). Unresolved
  CNumber defaults to `MInt`.

**Type-variable identity** (the April 2026 re-foundation): variables are
globally-unique sequential Int `MVarId`s assigned in a Phase-0 pre-pass
(AssignMVarIds), **backed by solver union-find roots** — two source tvars
unified during constraint solving map to the same MVarId via `rootEnv`, with a
per-binding name-scoped fallback for un-rooted vars. Constraint membership
lives in a side table (`MVarEnv.numberVars : Set Int`), per the explicit
side-table doctrine in `Id.elm`. Global uniqueness is what licenses
occurrence-based substitution filtering (`applySubstWithFreeVars` +
`closureOverSubst`) to prevent cross-scheme contamination.

**Unification policy: best effort, silent failure.** `TypeSubst` contains no
crash. Mismatched arms are no-ops; occurs-check failures skip the binding;
re-binding is "propagate the old binding via `unifyMonoMono`, then last write
wins." The consequence is a signature failure mode: constraint-loss bugs never
error in the monomorphizer — they surface as far-away MLIR verifier errors or
runtime kernel crashes (`mul_Float` receiving i64).

The spine, concretely: `processWorklistPure`/`processOneWorkItem`
(Monomorphize.elm:429–520) → `specializeNode` (Specialize.elm:1709) →
`specializeExpr` (2451) → {`specializeLambda`, `specializeDef`,
`specializeDecider`/`specializePath`, `specializeExprs`} + `enqueueSpec` (238)
+ `getOrBuildSchemeInfo` (78) + `TypeSubst.{unify, unifyExtend,
unifyCallSiteDirect, applySubst}` + `callResultMonoType` (5615). Call sites are
the engine of refinement: two-phase argument processing, scheme freshening,
single-pass call-site unification, callee enqueued at the unified type.

---

## 4. The two hostile features

The forward-only engine assumes demand arrives *with* the work item: by the
time you specialize an expression, its substitution already determines every
type. Two Elm features violate this:

**The `number` class under let-generalization.** `let n = 1 in n * 1.5` — at
the binding, `n`'s type is an unresolved `number` tvar; the Float demand lives
on a *use site*, possibly hops away (through a tuple destructure, a case, a
call). Producer-first specialization must either wait (defer) or guess
(default to Int). The pass guesses — inside `applySubst` itself — and then
deploys layers of machinery to detect and undo wrong guesses.

**Row polymorphism.** An accessor `.field : { ext | field : T } -> T` or a
row-polymorphic record arg has no complete layout until *sibling* information
arrives (another argument at the same call site, or the call-site result type).
Forward substitution silently narrows the row (drops the extension), producing
wrong layouts downstream.

Both are instances of the same statement: **in Elm, concreteness demand flows
from consumers to producers**, and a unidirectional eager engine cannot see it
in time.

---

## 5. The accretion strata: five retrofits of backward demand flow

Each stratum is the same idea — *postpone or repair producer-side decisions
until consumer demand is known* — implemented independently at a different
syntactic granularity.

**S1. Substitution enrichment** (in-place backward pushes into the subst).
`refineSubstFromArgExprs` (container-element bindings from already-specialized
args), `pushExpectedType` ("Fix 2": push a concrete if/case result type into
branch substs so a `number` branch doesn't default), per-field `unifyExtend`
in Record/Update arms, and — most principled — **scheme-residual unification**
(`unifyCallSiteDirectWithExpected`, TypeSubst:1490–1597): unify the callee
scheme's *unconsumed* params + result against the call's expected type, so a
first-class polymorphic argument (a `swap` passed to `List.map`) receives
constraints from context. Includes a sub-patch re-wrapping surplus arrows for
over-application. Deployed only on the `VarGlobal` polymorphic call path;
other callee paths still use the plain unifier.

**S2. Deferral — the five `Pending` variants.** When an argument cannot be
typed until the callee's parameter types are known, wrap it and resolve
positionally after call-site unification (`ProcessedArg`, Specialize.elm:59–66;
resolution 4630–4794). The variants arrived one bug at a time:

| Variant | Date | Trigger |
|---|---|---|
| `PendingAccessor` | Jan 16 (`d445124`) | `.field` arg needs the full record layout (MONO_015) |
| `MonoAccessorValue` (IR-level residual) | Mar 30 (`9b64add`) | standalone accessor still polymorphic → placeholder node, eliminated by the later ResolveAccessorValues sub-pass, crash-backstopped in codegen |
| `PendingGlobal` | Mar 19 (`345dac2`) | polymorphic global passed as argument |
| `PendingCall` | Apr 5 (`73ca8a2`) | nested call whose result still contains a CEcoValue MVar |
| `PendingNumberValue` | Jun 9 (`d133eba`) | number-multi hook (S3) |

Each resolves by the same trick: `unifyExtend canType paramType savedSubst`,
then re-enter `specializeExpr`. The *shape* (defer-until-param-known) is
principled; five variants with five bespoke trigger predicates
(`containsAnyMVar` vs `containsCEcoMVar` vs stack membership…) is accretion.

**S3. Local multi-specialization — the worklist re-implemented at let scope,
three times.**

- `localMulti` (Feb 24–25): let-bound *functions* used at several types.
  Inverts evaluation order — push a stack entry, specialize the **body first**,
  let call sites record instances, then emit one renamed clone per instance as
  a nested `MonoLet` chain. This is structurally the global fixpoint in
  miniature (discover demands, then discharge), done with stacks and renaming
  instead of the registry.
- `valueMulti` (Mar 12): let-bound *values containing lambdas* (e.g. a
  destructured lens pair). Adds partial-container synthesis
  (`buildPartialContainer`: leaf demand + fresh CEcoValue fillers for unknown
  sibling slots), destructor tagging (`tagValueInstanceWithDestructor`) so a
  later call through a destructor-bound name threads refinement back to the
  owning instance, and emission-time re-derivation of the instance type from
  its refined subst.
- `number-multi` (Jun): non-function `number` lets. Full deferral broke
  localMulti ordering, so this is a hybrid: specialize eagerly (Int), *seed*
  the valueMulti stack with the eager instance, then emit additional Float
  instances discovered by S2/S4. Guarded by a five-predicate gate
  (Specialize.elm:3569): `hasUnresolvedNumberVar && isNumericFixableShape &&
  (isNumericDataRhs || (isScalarNumberShape && demandedNumericUseType ≠
  Nothing))`, plus a post-hoc `localMultiInstanceCount` bailout making
  number-multi and localMulti mutually exclusive per binding. Every predicate's
  doc names the regression class it fences off ("Fix 1 + 7", the
  boxed-custom-SIGSEGV class, `EmbeddedNothingInCustomTypeTest`).

The three mechanisms share the `ctx.valueMulti` stack as an untagged union,
discriminated by re-running `isNumberMultiTarget` at every use site — priority
encoded by repetition, not by data.

**S4. Demand replay.** `collectNumericDemands`/`callArgDemands`/
`demandedNumericUseType` (834–964): before committing a `number` binding, walk
the **un-specialized** TOpt body for uses of the name as a call argument and
*replay* each enclosing call's unification (`unifyArgsOnly` with keep-number
arg types) to see whether any use demands Float. A shadow static analysis
duplicating what `specializeExpr` will do anyway — a clever but plainly
retrofitted answer to an ordering problem (binding emitted before uses are
seen). Consumed by the number-multi gate and by the `Destruct` float-demand
check.

**S5. Value-derived types ("trust the value, not the type").** For `Tuple`,
`Record`, `TrackedRecord` (and weakly `List`), the container MonoType is built
**from the specialized child expressions** (`MTuple (List.map Mono.typeOf
allExprs)`, :4347), demoting the substituted canonical type to a "refinement
hint." This contains upstream constraint-flow gaps at the last boundary where
correct information exists — the May 2026 fix for unboxed-bitmap/GC corruption.
Note it flows the *opposite* direction from S1 and does **not** write back into
the subst, so siblings deriving types from the canonical route can disagree
within one expression.

On top of the strata sit paired **guards** keeping them from fighting: the
`Destruct` concreteness guard (:3839) disables S3-refinement on concrete roots
to protect layout consistency (CGEN_040), then carves a hole for S4's Float
demand (`&& floatDemand == Nothing`) — a guard on a patch, patched;
`monoTypeContainsFloat` refuses to record Int-demand instances to avoid
perturbing localMulti. Each mechanism pair has a bespoke tie-breaker rather
than a shared arbitration principle.

---

## 6. The `number` saga

The single feature that generated the most drift. Five successive models:

1. **Dec 2025** (`aa8bca9`): constraint zoo reduced to `CEcoValue + CNumber`.
2. **Jan 2026** (`65a74fa`): let number types flow unresolved (replacing the
   one-day-lived `IncompleteType` mechanism).
3. **Feb 2026** (`7b8e26f`): eager default — resolve number vars to Int.
4. **Apr 2026** (`cd19d7a`): preserve unresolved CNumber so Float operators
   can specialize as Float (`applySubstKeepNumber` is born).
5. **Jun 2026** (`d133eba` + follow-ups): demand-driven use-site
   specialization (PendingNumberValue, number-multi, demand replay).

Two structural decisions make this feature chronically fragile:

**The lossy entry channel.** The solver *knows* which variables are
number-constrained, but that fact is not exported through `SolverRoots`.
Instead AssignMVarIds re-derives it from the **name prefix**:
`constraintFromName name = if Name.isNumberType name then CNumber else
CEcoValue` (AssignMVarIds.elm:148–154), where `isNumberType = String.startsWith
"number"`. Every downstream wart in the project's bug memory — solver-root
reuse dropping the flag, the join-upgrade patch in `ensureMVarIdForRoot`
(:192–216), the gate tower — is compensation for this channel. Any pipeline
stage that invents or renames a tvar without the prefix silently drops the
constraint.

**Defaulting during iteration instead of at quiescence.** CNumber→MInt firing
is now *inside* `applySubst` (TypeSubst:555–557, 654–656) — so **every
`applySubst` call is a defaulting point**, and it fires long before all demands
have been observed. In fixpoint terms: defaulting is a *closing operator* that
is only sound at the fixpoint, but the code applies it at every step and then
builds S2–S4 to detect and undo premature closures. The fossil that proves the
migration: `forceCNumberToInt` — wrapped around essentially every `applySubst`
result — is now the **identity function**, "kept as identity to avoid churn at
57 call sites" (Monomorphized.elm:267–272). Its counter-operator
`applySubstKeepNumber` (TypeSubst:955–1123) is a full structural clone of
`applySubst`; correctness of the number system depends on picking the right
one of the two at each of ~60 sites.

---

## 7. Module-by-module: skeleton vs noise

| Module | Intended skeleton | Principal noise |
|---|---|---|
| `Monomorphize.elm` (745) | Seed → drain → assemble → prune; `inProgress`/`scheduled` BitSets; deferred callEdges/effects analysis | `updateRegistryType` patching the registry *after* each node because demand-type ≠ actual node type (legislated by MONO_017) |
| `State.elm` (349) | accum/ctx split (monotone accumulator vs scoped context — a measured perf refactor); frame-stack `VarEnv`; `MVarEnv` allocator + side table | `localMulti`/`valueMulti` stacks with `derivedDestructorNames` — S3's state |
| `Specialize.elm` (5,973) | ~2,000-line spine (§3) | ~2,000 lines of S1–S5 + gates; quadruplicated eager-let fallback; copy-paste `Tracked*` twins; cycle-path duplication |
| `TypeSubst.elm` (1,778) | Canonical↔mono unification, path-compressed union-find inside the subst, occurrence-filtered application, scheme freshening, merged single-pass call-site unifier | `applySubstKeepNumber` clone; ignored `FreeVars` parameter (vestige of the pre-MVarId name-based design); silent-failure policy pushing all diagnosis downstream |
| `AssignMVarIds.elm` (1,158) | Phase-0 rewrite Names→MVarIds; solver-root-backed identity (`rootEnv`), per-binding scheme separation | Name-prefix constraint channel; **duplicated root-claim logic, only one copy carrying the CNumber join patch** (§9.1) |
| `Closure.elm` (808) | Free-variable analysis → inline `MonoClosure` captures; no lifting | Capture-*type* recovery stack (scrape body for first typed occurrence → reverse-infer case-root types from decision-tree tests → `MUnit` fallback → crash) — all compensating for untyped `MonoCase` scrutinee roots in the IR |
| `KernelAbi.elm` (426) | Two-mode (`UseSubstitution`/`PreserveVars`), two-layer (neutral/backend) model; kernels as leaves | `suffixSelectingKernels` — a phase-tagged, per-bug-annotated registry that must stay in sync with a giant backend symbol match ("This set is **load-bearing**, not a transitional shim") |
| `ResolveAccessorValues.elm` (674) | (Is itself a patch.) Internally principled: abstract-interpretation lattice (`VI_Unknown/VI_Accessor/VI_Record`) + context-rooted typed closure fallback | Runs per-node inside the worklist loop; "leave as-is" escape contradicting its header guarantee; stale MONO_027 citation; "TIER 2+3" renumbering scar |
| `MonoTraverse.elm` (492) | Generic bottom-up rewrite + fold over the 18-variant IR | Serves only analyses; none of the scope-sensitive passes can use it |
| `Prune.elm` (177) | MONO_022 reachability over cached callEdges; **nulls, never compacts** (SpecId stability) | Port/flags roots bolted on per feature (PORT_003), each needing a comment explaining why it would otherwise be swept |
| `Registry.elm` (99) | Minimal SpecKey interner | Dead `Maybe LambdaId` axis |
| `Monomorphized.elm` (1,329) | Closed SpecId-indexed graph; two-constraint contract; shapes-not-layouts; staging as nested `MFunction` | `MonoAccessorValue` phase-leak; placeholder `CallInfo`/`closureKind` owned by GlobalOpt; identity `forceCNumberToInt`; three single-constructor enums whose docs describe deleted siblings |

---

## 8. What the history shows

Growth of Specialize.elm (and precursor): 1,452 (birth) → 2,421 (Dec rewrite)
→ 3,144 → **1,597 after the Jan 15 module split** → **1,868 after the Feb
GlobalOpt extraction (a shrink)** → 3,622 (Mar, PendingGlobal) → 4,828 (Apr)
→ 5,973 (Jun 12) → flat since. 221 commits total; Specialize.elm alone took
107 (48%); ~40% of commits are corrective once fixes hiding behind
"Preserve/Prevent/Restrict/Defer" are counted.

Three shapes stand out:

1. **The pass improved by subtraction, not addition.** Its three best design
   moments (layout out, staging out, kernel policy out) all *removed*
   responsibilities. Every month of heavy addition (Mar–Jun demand machinery)
   was compensating for the eager-defaulting misalignment.

2. **The April crisis produced the one true re-foundation.** 43 commits in
   April, mostly "type poisoning"/"cross-scheme contamination" bugs, forced
   MVarIds (`f361817`) and solver-root identity (`b88f80c`). Notably that idea
   was **harvested from an abandoned rewrite**: `MonoDirect`, a clean-slate
   solver-directed monomorphizer (Mar 12–31, ~5,400 lines, deleted with
   "revert this commit to restore it"), whose SolverSnapshot concept the
   mainline adopted a week after deletion. The failed rewrite was the design
   probe; the harvest was real.

3. **Stabilization is genuine.** Since Jun 12 the file is byte-stable and
   commit rate dropped to ~10/month, i.e. the demand-driven retrofits have
   (for now) covered the miscompile classes. This is the window in which
   consolidation is cheap.

Other abandoned experiments, each a one-way-door probe: `IncompleteType` (one
day, Jan), `Segmentation.elm` (same-day, Feb), `NumberBoxed` kernel mode
(Feb→May, subsumed by per-instance ABI), `MErased`-in-mono (dropped Mar with a
"poisoning" design note; the *name* returned later as a codegen-side concept,
MONO_023), early `"?"`/`_unknown` placeholders replaced by crashes — an early,
deliberate shift to fail-fast.

---

## 9. Fossil catalog (and one live bug)

### 9.1 Latent live bug: unjoined constraint on annotation root reuse

The CNumber join-upgrade patch ("number dominates" when a second name claims an
already-claimed solver root) exists in `ensureMVarIdForRoot`
(AssignMVarIds.elm:192–216, with a comment citing
`fix-number-constraint-lost-solver-root-reuse.md`) — but the **same root-claim
logic is duplicated inline in `rewriteAnnotation` (:287–299) without the
upgrade**. A `number`-named annotation binder whose root was already claimed by
a non-number name in an earlier annotation still silently loses the constraint
— exactly the bug class the patch was written for, alive in the unpatched copy.

### 9.2 Vestiges and duplications

- `forceCNumberToInt`: identity at ~57 call sites (documenting where defaulting
  used to live).
- `applySubstWithFreeVars` ignores its `FreeVars` parameter entirely
  (TypeSubst:804) — pre-MVarId API fossil.
- The lambda-set axis: `SpecKey`'s `Maybe LambdaId` threaded everywhere, always
  `Nothing`; `LambdaId` has one constructor; MONO_019 tests uniqueness of ids
  that never key anything.
- Single-constructor enums with docs describing deleted siblings: `MainInfo =
  StaticMain`, `ClosureKind = Known`, backend `KernelBackendAbiPolicy =
  ElmDerived`.
- The eager-let fallback block (specializeDef → concreteness/widening compare →
  maybe enrich subst → maybe **re-specialize the whole body a second time** →
  `MonoLet`) appears four times essentially verbatim (:3184–3253, :3321–3378,
  :3416–3481, :3749–3810) plus an abbreviated fifth (:3600–3626). The double
  body specialization also duplicates side effects (enqueues, outer-stack
  instance recording, lambdaCounter bumps) with no rollback — safe today only
  via instance-key dedup.
- `VarLocal`/`TrackedVarLocal` and `Record`/`TrackedRecord` arms: copy-paste
  twins.
- Cycle handling: `specializeFunctionCycle` generalized to subsume
  `specializeValueCycle`, which is retained anyway; requested-node
  lookup + MonoExtern fallback duplicated with a "belt-and-braces" admission.
- `hasCEcoTVar` is `not << all isNumberVar` under a misleading name;
  `isFullyMonomorphicType` ≈ `not << containsAnyMVar`.
- `MVar`'s embedded `Constraint` duplicates the `numberVars` side table (path
  compression must re-stamp it via `constraintOf`).
- Stale doc references: ResolveAccessorValues header cites MONO_027 (now the
  arity invariant); "TIER 2+3" banner after tier 1 was deleted; KernelAbi
  comments referencing the removed `numberBoxedKernels` table.

### 9.3 Crash messages as the real specification

The most reliable map of the design's load-bearing walls is its crash set:
`"no annotation entry for global …"` (annotation totality — the observable
symptom of a silently-empty typed-artifacts load); `specializePath`'s
shape-mismatch crashes (concreteness-at-projection deadline — the wall S3/S5
protect); `"missing type for captured var … violates Mono typing invariants"`;
`"MonoAccessorValue … should have been eliminated by ResolveAccessorValues"`;
the multi-stack underflow crashes (D7: silent skipping "would reintroduce
exactly the class of bugs this tagging fixes").

---

## 10. The design, elevated

The statement the code is converging toward, made explicit:

> **Monomorphization is a demand-driven fixpoint over interned
> (definition, type) pairs, in which *all* type information flows through one
> substitution per discharge, demand may flow both forward (producer→consumer)
> and backward (consumer→producer) before a type is committed, and the two
> residual obligations — erasable boxing (`CEcoValue`) and numeric defaulting
> (`CNumber`) — are discharged only at the boundary, never during iteration.**

Measured against that statement, the accretion resolves into three principled
gaps rather than dozens of patches:

1. **Constraint provenance.** `number`-ness should be a fact exported by the
   solver through `SolverRoots` alongside root identity — not re-derived from
   name prefixes and re-joined by patches. One channel, loss-free, kills the
   whole recovery apparatus at the entry side (including bug §9.1).

2. **Defaulting placement.** CNumber→MInt is a closing operator; it belongs in
   exactly one place — a final resolution step at fixpoint quiescence (or at
   minimum, at node-emission boundaries after all call-site/branch demand has
   been unified). With late defaulting, `applySubstKeepNumber` merges back
   into `applySubst`, the demand-replay analysis (S4) becomes unnecessary, and
   the number-multi gate tower (S3's third stack) loses its reason to exist.

3. **One deferral concept, one local fixpoint.** The five `Pending` variants
   are one mechanism (defer until consumer type known) and should share one
   representation and one resolution path. Likewise localMulti/valueMulti/
   number-multi are the global worklist re-implemented at let scope; the
   uniform design lifts let-bound polymorphic definitions into (scoped)
   specialization keys handled by the *same* fixpoint, rather than shadow
   stacks with renaming. (The staging-agnostic contract makes this safe: mono
   never needs lets in place for calling-convention reasons.)

Secondary consolidations that fall out: extract the quadruplicated eager-let
fallback (and eliminate double body specialization); give `MonoCase` a typed
scrutinee root (collapsing Closure.elm's type-recovery stack); delete the
LambdaId axis or commit to it; delete the identity `forceCNumberToInt` and the
other §9.2 fossils; replace the valueMulti untagged union with tagged entries.

None of this is a rewrite. The spine — worklist, registry, solver-root
MVarIds, freshening, occurrence-filtered substitution, staging-agnosticism,
shapes-not-layouts, the two-constraint contract — is sound and battle-tested.
The noise is concentrated precisely where the original eager model met Elm's
backward-flowing demand; naming that as *the* design problem is what turns
seven months of patches back into a theory.
