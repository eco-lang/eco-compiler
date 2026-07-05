# Reusing the HM Solver in Monomorphization: Viability Evaluation

*Evaluation of the proposal to replace the monomorphizer's independent type
machinery (TypeSubst.elm and friends) with the type checker's solver, so that
one load-bearing engine understands Elm's type space. Sources: full reads of
`Compiler/Type/{Solve,Unify,UnionFind,Instantiate,Occurs,SolverSnapshot,
SolverRoots,Type,PostSolve}.elm` and `System/TypeCheck/IO.elm`; the
TypedOptimized IR and its binary codecs; `design_docs/hm-solver-reuse.md`;
the eleven `plans/*monodirect*.md` documents; and a code-level post-mortem of
the deleted MonoDirect experiment (recovered from the public mirror at
`3a6fac7^`). Builds on `design-recovery.md` in this directory.*

---

## 1. Verdict

**Viable, strategically right, and — in one specific architecture — much
cheaper than it looks. But the architecture matters enormously: one of the
three ways to do this has already been tried in this repo and failed for
reasons that are now documented, and the user-proposed form (store/recompute
constraints per module) is more machinery than the goal requires.**

The recommended shape is not "re-run the typechecker during monomorphization"
and not "query frozen per-module solver snapshots." It is:

> **Keep the monomorphizer's demand-driven worklist exactly as it is, and swap
> its unification engine: per work item, build a small fresh solver store,
> load the definition's typed IR into it (MVarId → union-find Point), run the
> real `Unify` at the same places TypeSubst runs today, and zonk each node's
> variable to a MonoType at readback — defaulting `number → Int` only there,
> at quiescence.**

This keeps the pass's identity (specialization policy, registry, IR
translation, closures, kernel ABI) and replaces only the part that duplicates
the type checker — which is exactly the part the design-recovery report found
to be the source of nearly all the pass's bugs.

Three findings gate the work:

1. **Two latent bugs in the current identity/constraint channel** must be
   fixed regardless of this proposal (§6.1): the unjoined CNumber upgrade in
   `AssignMVarIds.rewriteAnnotation`, and — found during this evaluation —
   **cross-module solver-root aliasing**: `rootEnv : Dict Int MVarId` is keyed
   by raw per-module `Pt` indices that restart at 0 every module solve, so
   unrelated definitions in different modules can silently share MVarIds (and
   the CNumber join can stamp number-ness across modules).
2. **The artifact format needs one small structural change first**: persist
   type-variable supers (number/comparable/…) as data instead of name
   prefixes, and module-scope the persisted root ids. (§6)
3. **Kernel types are the honest-breakage frontier**: they are post-hoc
   fabrications (first-usage-wins inference in PostSolve), and a real unifier
   will reject what the silent one absorbs. This is where migration effort
   concentrates. (§6.3)

---

## 2. This has been tried before — the repo contains a complete map of the minefield

The proposal is not new to this codebase, which is the single most useful
fact for evaluating it.

**Prior art 1: `design_docs/hm-solver-reuse.md`** — a full design sketch
(status "Idea / Exploration Only") of the Roc pattern: keep a per-module
solver snapshot, provide `withTemporaryUnification` (relax rigids → unify →
query → rollback), replace PostSolve with snapshot extraction and
monomorphization's TypeSubst with snapshot queries. It includes a complete
invariants-delta appendix (proposed `SNAP_*`, `POST2_*`, `MONO_SNAP_*`,
`XSNAP_*` invariants) that remains directly reusable.

**Prior art 2: MonoDirect** (2026-03-12 → 03-31, deleted; ~5,400 lines +
eleven plan docs that survive in `plans/`). A parallel, test-only
monomorphizer implementing exactly that snapshot architecture:
`SolverSnapshot` captured the solver's three union-find arrays plus
`nodeVars : Array (Maybe Variable)` (expression id → solver var) and
`annotationVars`; each specialization fabricated a throwaway local `IO.State`
from the snapshot (O(1), persistent arrays), relaxed rigids on the fly, ran
the **real** `Unify.unify` against synthesized variables encoding the
requested MonoType, and read every sub-expression's type back via
`view.monoTypeOf tvar`. Its founding plan states the intended payoff, which
is the same as this proposal's:

> "No string-based variable names → no renaming / collision issues. No
> SchemeInfo, buildRenameMap, unifyCallSiteWithRenaming. Single unification
> step resolves all types simultaneously. No per-expression applySubst
> traversal."

It reached ~99.2% parity (75 failures / 9,468 tests, single-module, test
pipeline only) and was deleted as "incomplete and getting in the way of other
refactoring." Four days later, mainline harvested its central insight —
solver union-find roots as type-variable identity — as `SolverRoots` +
root-backed MVarIds (`b88f80c`), for a few hundred lines instead of 5,400.

**Why MonoDirect actually failed — three specific reasons, all avoidable:**

1. **The snapshot lacks instantiation edges.** The post-solve union-find has
   already *consumed* the let-polymorphic structure mono needs: generalization
   copies variables per use (`makeCopy`), so a body's recorded tvars point at
   the generic scheme, disconnected from any particular use. MonoDirect's own
   `LocalView.subst` docstring concedes it: tvars "not connected in the solver
   (e.g., after let-polymorphic instantiation disconnects original tvars from
   the function's type structure)" — and its workarounds were a `specStack`
   replay of enclosing unifications, a **TypeSubst fallback that crept back
   in** (a "Phase 8: Eliminate TypeSubst Fallbacks" plan was still open at
   deletion), and a two-pass throwaway body specialization for local
   polymorphism.
2. **`Maybe tvar` coverage metastasized.** Per-node solver-variable handles
   require every optimizer pass to preserve them. 90 LocalOpt construction
   sites hardcoded `tvar = Nothing`; synthetic nodes (decision trees, port
   codecs, accessor bodies) have *no* canonical origin and hence no solver
   variable, ever. The "no fallback, missing tvars are hard errors" purity
   goal made this an unbounded prerequisite.
3. **No multi-module story.** Snapshots were never persisted into `.ecot`;
   `Pt` indices are per-module; the whole experiment ran single-module while
   production mono is whole-program.

These are failures of the *snapshot-and-handles* architecture, not of solver
reuse. The recommended architecture (§4) is chosen point-by-point to avoid
them.

---

## 3. Three architectures, and which one this proposal should mean

**Architecture A — store/regenerate constraints; re-solve per specialization.**
The literal reading of the proposal ("recomputing the constraints for each
module… propagating those constraints along… building a constraint set to
solve, solving it"). This treats mono as re-typechecking with some variables
pre-bound.

*Assessment: more machinery than the goal requires.* The key observation
(from the artifact-fidelity audit): **constraints are re-derivable from the
IR's structure — a Call node *is* a unification obligation; a Let *is* a
generalization point — but variable identity and constraint-ness are not
re-derivable, and those are exactly what the artifacts currently store
lossily.** Storing or regenerating the original constraint tree would also
have to bridge a real gap: constraints were generated against the *canonical*
AST, and mono runs on *TypedOptimized* — a different tree (decision trees
compiled, ports lowered, lambda boundaries normalized, synthetic nodes
inserted). Mapping canonical constraints onto TOpt nodes is precisely the
provenance problem that sank MonoDirect's tvar plumbing. A fresh constraint
generator over TOpt would work, but it's unnecessary: TOpt already carries a
solved type on every node; the "constraints" mono needs are just the
equalities it already knows to assert (scheme ~ demand, param ~ arg,
branch ~ result). What it lacks is a trustworthy engine to assert them into.

**Architecture B — per-module snapshots + per-node tvar handles + temporary
unification.** The hm-solver-reuse.md / MonoDirect / Roc pattern.
*Assessment: tried; failed for the three documented reasons above.* The
instantiation-edge problem is fundamental to it, not incidental: no amount of
tvar plumbing recovers edges the solver discarded at generalization time.

**Architecture C (recommended) — solver as unification kernel under the
existing worklist; fresh store per work item, loaded from typed IR.**

Per specialization work item:

1. Allocate a fresh (or reset) solver `State` — trivially cheap; `State` is a
   plain record of persistent arrays and `IO a = State -> (State, a)` is a
   pure function, so "a store" is just a value (§5.1).
2. Build a per-instance `MVarId → Point` memo. Loading a `Can.Type MVarId`
   into the store is a small variant of the existing
   `Solve.srcTypeToVariable`/`Instantiate.fromSrcType`: each distinct MVarId
   becomes one `FlexVar`/`FlexSuper Number` Point (supers from the
   structurally-persisted constraint, §6.2); structure becomes `Structure
   FlatType`.
3. Unify the definition's loaded scheme against the demanded MonoType
   (encoded as concrete structure — MonoDirect's `monoTypeToVar` shows the
   ~50-line recipe), then walk the body exactly as `specializeExpr` does
   today, asserting at each call site / branch / binding the same equalities
   TypeSubst asserts today — but into the union-find, in any order.
4. Zonk each node: `zonkToMono` (a ~100–200-line sibling of
   `variableToCanType` minus the naming machinery), with the defaulting
   policy applied **only here**: `FlexSuper Number → MInt`, residual
   `FlexVar → MVar CEcoValue` (kernel positions), `Error → crash loudly`.
5. Discard the store (or snapshot-restore around speculative unifications —
   free with persistent arrays).

Why C dodges each MonoDirect failure:

- *Instantiation edges*: not needed from the solver — **the worklist is
  already mono's own instantiation mechanism**. Callee schemes are freshened
  per call site (today via `refreshSchemeInfo`; under C via the solver's own
  `makeCopy`, which even performs the rigid→flex relaxation natively,
  `Solve.elm:1093-1099`). Per-instance stores mean cross-specialization
  contamination is impossible *by construction* — the entire April-2026
  poisoning bug class becomes unrepresentable.
- *tvar coverage*: C works from `meta.tipe`, which is **total** (every node
  carries it, including synthetic ones), not from `meta.tvar`, which is
  partial and dropped at the codec anyway. No optimizer-pass prerequisite.
  Per-node tvars become an optional future precision upgrade, not a gate.
- *Multi-module*: a non-issue. Nothing is loaded from per-module solver
  address spaces; everything enters the store through types keyed by
  globally-unique MVarIds — the identity space `AssignMVarIds` already
  builds (after the scoping fix, §6.1).

And why C still delivers the stated goal — "the load-bearing code that truly
understands the type space of Elm sits in a single reusable piece": what gets
shared is the part that *is* load-bearing — `Unify` (records/rows, supers,
aliases, tuples, occurs), `UnionFind`, `makeCopy` instantiation, zonking.
What mono keeps (knowing *which* equalities to assert) is thin and mirrors
the IR structure, not a second theory of types.

---

## 4. What C dissolves — mechanism by mechanism

Measured against the accretion catalog in `design-recovery.md`:

| Current mechanism (lines, approx.) | Fate under C | Why |
|---|---|---|
| `TypeSubst.elm` unification + `applySubst` + `applySubstKeepNumber` + free-var filtering (~1,778) | **Deleted** | Replaced by `Unify` + zonk. The `applySubst` vs `applySubstKeepNumber` fork exists only because defaulting fires inside substitution; with defaulting at zonk there is one path. |
| Five `Pending*` deferral variants + two-phase `ProcessedArg` (~400) | **Deleted** | Deferral exists because Dict-substitutions are directional and order-sensitive. Union-find is order-*independent*: unify args, params, and expected result in any order; information flows through shared Points. Phase structure collapses to "assert all equalities, then zonk." |
| `unifyCallSiteDirectWithExpected` scheme-residual + over-application re-wrapping | **Deleted** | Just more equalities asserted before readback. |
| Number demand replay (`collectNumericDemands`, ~130) + number-multi gate tower (~300) + `pushExpectedType` | **Deleted** | These exist to observe Float demand before eager defaulting fires. With defaulting only at zonk, all uses in the body are unified before any commitment — demand is observed by construction. |
| `localMulti` / `valueMulti` stacks + destructor tagging (~600) | **Simplified, not deleted** | Discovery and typing come from per-use unification + distinct zonked instances (use sites already carry their own instantiation vars in the typed IR — the fidelity audit confirmed identity is per-use, not per-scheme). The *mechanics* (cloning defs, `renameMonoDef`, emitting `MonoLet` chains) remain. One genuine design point survives: see §6.4 on re-linking let boundaries. |
| Element-derived container types (S5, "trust the value") | **Becomes an assertion** | Under a sound engine, the canonical-derived and child-derived types must agree; keep the comparison as a loud invariant check during migration, then drop. |
| `recordWidened` / `isMoreConcrete` row repairs | **Deleted** | Real row unification (`Record1 fields ext`) doesn't lose extensions. |
| Silent-failure unification policy | **Inverted** | `Unify` returns `Answer`; mismatch in mono = compiler bug = crash with both types. The `mul_Float (f64, i64)` family of far-away failures becomes a near failure at the responsible call site. |
| `forceCNumberToInt` identity fossil (57 sites), ignored-FreeVars param, scheme cache freshening | **Deleted** | Roles subsumed by zonk policy / `makeCopy`. |

Net estimate: **~3,000–3,500 lines of the pass's most bug-dense code deleted**
against roughly **500–800 new** (store loader, `unifyPair`, `zonkToMono`,
MonoType→structure encoder, solver API wrappers). The spine — worklist,
registry, node dispatch, closures, ports, kernel ABI modes, prune — is
untouched.

---

## 5. Feasibility findings

### 5.1 The solver is cleanly re-entrant (better than Roc's, for this purpose)

- `type alias IO a = State -> (State, a)` (`System/TypeCheck/IO.elm:132`);
  `State` is six fields: the three union-find arrays (weights, pointInfo,
  descriptors), the rank-pool backing array, a name-supply (used only by
  annotation/error rendering), and constraint-gen node ids. **No ambient
  state, no hidden counters** — fresh variables are minted by array-push, so
  the array is the supply. Running against a hand-built store is just
  function application; `Solve.runWithIds` already extracts snapshots by
  copying the three arrays (`Solve.elm:124-137`).
- **Snapshot/rollback is free** (persistent arrays) — where Roc needs
  explicit typestate snapshot/rollback machinery, eco keeps an old value.
- `Unify.unify : Variable -> Variable -> IO Answer` — mismatch is a value,
  not an exception. Two sharp edges to wrap: on failure it (a) **poisons**
  both trees with `Error` content (`Unify.elm:68`) and (b) is
  **non-transactional** (sub-term merges before the mismatch are committed).
  For mono the right policy is "failure = compiler bug, crash loudly"; where
  speculative unification is wanted during migration, capture the three
  arrays first and restore. A mono-facing `unifyPair` that skips the
  `toErrorType` rendering (which writes names/marks into descriptors) is
  ~30 lines.
- **Instantiation is ready-made**: `Solve.makeCopy` copies only
  generalized (`noRank`) variables, shares monomorphic ones, memoizes via the
  descriptor `copy` field, and converts `RigidVar → FlexVar` /
  `RigidSuper → FlexSuper` in the copy — the Roc `instantiate_rigids`
  analogue built in. `Solve.srcTypeToVariable` already converts a
  `Can.Type Name` into store variables *with number-name→`FlexSuper Number`
  mapping* — the store loader is a small generalization of existing code.
- **Generalization machinery is not needed.** Ranks/pools drive
  let-generalization during checking and are inseparable from constraint
  order — but mono only *consumes* schemes (instantiate), never produces
  them. Fresh stores at a single rank sidestep the whole subsystem (pass a
  dummy pool to `makeCopy`, or add a no-pool variant).
- **Readback**: `zonkToMono` modeled on `Type.variableToCanType`
  (post-order walk, `UF.get` + dispatch), minus naming, plus defaulting
  policy. ~100–200 lines; runs against a bare store.

### 5.2 The typed IR is a good compression of *types*, a lossy compression of *identity and constraints*

- Every TOpt node carries `Meta = { tipe, tvar }`. `tipe` is total and
  persisted. `tvar` (per-node solver variable, root-normalized) is populated
  in-memory but **read by nobody and dropped by the codec** — it is
  MonoDirect's vestigial plumbing. C does not need it.
- `schemeRoots` (per-def binder → rooted solver var) *is* persisted — as raw
  per-module `Pt` ints. Within a module, sticky batch naming makes
  name-identity ≈ solver-identity; across modules, the raw ints alias (§6.1).
- **Per-use instantiation identity exists in the IR**: use sites of
  let-generalized bindings carry their own instantiation variables and
  names, distinct from the def's scheme vars. This is what makes
  Architecture C's uniform treatment of local polymorphism sound.
- **Fabricated types are the fidelity gaps**: PostSolve Group-B repair
  (harmless: concrete literal types), PostSolve fallback fabrications
  (`Can.TVar "a"` / `"result"` — invented names that can *collide* with
  legitimate fresh names in the same def), Port lowering placeholders
  (`TVar "destruct"`, `TVar "encodeBytes"`), and — the big one — the entire
  **kernel-type universe**, inferred first-usage-wins by PostSolve's private
  name-based mini-unifier. Today's silent unifier absorbs all of this; a
  real unifier will reject the inconsistent parts loudly. That is the
  correct end state and the main migration cost.

---

## 6. Prerequisites and design points

### 6.1 Fix the two latent identity bugs (do this regardless)

1. **`rewriteAnnotation` unjoined constraint** (found in the design-recovery
   review): the CNumber join-upgrade patch exists in `ensureMVarIdForRoot`
   but not in the duplicated root-claim logic in
   `AssignMVarIds.rewriteAnnotation` (~:287–299) — a number-named annotation
   binder whose root was claimed earlier by a non-number name silently loses
   the constraint.
2. **Cross-module root aliasing** (found in this evaluation): each module's
   solve restarts `Pt` indices at 0 (`unsafePerformIO` seeds empty arrays),
   but `AssignMVarIds` keeps one global `rootEnv : Dict Int MVarId` across
   the whole graph — def A in module M1 with binder root `Pt 42` and an
   unrelated def B in M2 with root `Pt 42` share an MVarId. Mostly latent
   (substitutions are per-work-item), but the global `numberVars` join means
   a number binder in one module can stamp CNumber onto an unrelated
   module's generic binder, silently changing its defaulting. Fix: key roots
   by `(module, idx)` or renumber at assembly.

### 6.2 Structural constraint export (small; independently valuable)

Extend the persisted per-def scheme info from `Name → rootInt` to carry the
binder's super (`Number`/`Comparable`/`Appendable`/`CompAppend`/none) — one
byte per binder, one codec version bump; the producer already holds the
descriptor `Content` at snapshot time. This replaces the name-prefix channel
(`constraintFromName`) with data, hardens the two bugs above into
non-recurrence, and gives the store loader honest `FlexSuper` seeds. This is
the same "give the type a structured slot" fix recommended in the earlier
number/lambda-set discussions — all three motivations converge on it.

### 6.3 Kernel-type honesty (the real migration frontier)

PostSolve's first-usage-wins kernel inference must become real schemes
(`KernelTypes.elm` is the natural home), and the `TVar "a"`/placeholder
fabrications must become explicitly fresh variables (reserved namespace or
genuinely fresh MVarIds) so the store loader can't alias them by name.
Expect this to unearth existing wrong-but-silently-absorbed types — each is a
latent miscompile candidate today, so the loud failures are diagnostic gold,
but they arrive on the migration critical path. Budget for it explicitly;
lesson 3 of the MonoDirect post-mortem ("decision trees, cycles, kernel ABIs
don't live in the solver — budget for them as first-class") applies verbatim.

### 6.4 Named design point: re-linking let boundaries

`AssignMVarIds.withFreshBinding` resets the name-scoped fallback env per
let-def, deliberately splitting even *monomorphic* sharing between a let
def's type and its enclosing body into distinct MVarIds. Under C, the load of
a def's RHS and the load of the enclosing body therefore produce Points that
must be **explicitly re-linked at the binding site**: instantiate the def's
scheme per use (generalized vars — via `makeCopy`, exactly like a top-level
call) while unifying the *captured/monomorphic* portion directly with the
outer scope's Points. This mirrors the solver's own `CLet` discipline and is
well-defined, but it is the one place C must be more careful than "assert
equalities anywhere" — the same corner where MonoDirect's two-pass replay
lived. It deserves a focused design note and its own test batch before the
engine swap reaches let-polymorphism.

### 6.5 Performance

Cost model per specialization: instantiate (O(scheme dag), array pushes) +
unify (near-linear, path-compressed, weight-balanced — and the hot path is
already deliberately flattened: `Descriptor` was collapsed to a bare record
"so it is read/written directly on the hot union-find path") + zonk (O(type
size)). Asymptotically equivalent to today's `Data.Map` substitution walks;
structurally better where types share variables (solve once vs re-walk per
occurrence); constant-factor risk from the CPS `Unify` monad's closure
allocation. Two mitigations: per-work-item stores stay small (locality), and
the readback can be memoized per Point. **Benchmark gate**: eco self-compile
wall time and the known pathological inputs (elm-aws-codegen) before and
after each migration phase — the same discipline as the GlobalOpt
exponential-staging incident.

---

## 7. Migration strategy — apply the MonoDirect lessons

The post-mortem's lesson 6 is the strategy: *"a second attempt should be
staged so each increment lands in the production pipeline behind the existing
tests, instead of accumulating in a shadow implementation that a refactor can
render unaffordable."* Concretely:

1. **Phase 0 — identity hardening** (§6.1 + §6.2). Pure fixes, independently
   valuable, land behind the full E2E suite. No solver involvement yet.
2. **Phase 1 — solver API surface.** `initStore`/`runIn`/`snapshot` wrappers,
   `unifyPair` (non-poisoning), `makeCopyNoPool`, `loadCanTypeIntoStore`,
   `monoTypeToVar`, `zonkToMono`. All new code, no behavior change; unit-test
   against `TypeSubst` on randomized types (property: where TypeSubst
   succeeds, the solver agrees; where they disagree, investigate — each
   disagreement is a candidate latent bug).
3. **Phase 2 — engine swap on the spine, strangler-style, inside the
   production pass.** Route the *monomorphic and simple-polymorphic* work
   items through the solver engine behind a flag, with an A/B assertion mode
   that runs both engines and diffs zonked types per node
   (alpha-normalized). This resurrects MonoDirect's best asset — the
   comparison harness — but *inside* the production pass, never as a
   parallel monomorphizer, and never `Test.skip`'d.
4. **Phase 3 — the hard corners in order of blast radius**: call-site
   unification (dissolves Pending variants), let boundaries per §6.4
   (dissolves multi-stack typing), kernel honesty per §6.3, cycles.
   After each: delete the corresponding TypeSubst-era mechanism and its
   gates, run `TEST_FILTER` batches plus self-compile.
5. **Phase 4 — TypeSubst removal.** When no production path imports it,
   delete it and `forceCNumberToInt`, and update the affected invariants
   (the hm-solver-reuse.md appendix already drafts the rewordings:
   MONO_008/015/020/021/024/025 reinterpret "substitution" as "the local
   solver scope's result").

Golden-gate discipline throughout, per the typechecker Design B methodology
already proven in this repo: byte-identical MonoGraph output (or
alpha-equivalent where SpecId numbering shifts) is the merge bar for each
phase.

---

## 8. Synergies

- **Lambda sets in mono** (previous discussion): a real solver store at mono
  time is the natural host for set-valued facts — row-like content unified
  with union semantics, using the same `Record1`-style machinery, without
  touching the type-checking phase. Architecture C turns "compute lambda sets
  during monomorphization" from a bespoke dataflow analysis into ordinary
  content in the mono store.
- **Number defaulting at quiescence**: the design-recovery report's #2
  recommendation falls out structurally (defaulting lives only in
  `zonkToMono`).
- **PostSolve 2.0**: once kernel types are honest schemes (§6.3), the
  hm-solver-reuse.md vision of PostSolve as a thin extraction layer becomes
  incrementally reachable — but as a *follow-on*, not a prerequisite.

---

## 9. Risk table

| Risk | Severity | Mitigation |
|---|---|---|
| Kernel/fabricated types reject under real unification | High (migration), positive (end state) | §6.3 first-class; A/B assertion mode localizes each case |
| Perf regression (CPS unify allocation, store churn) | Medium | Per-item stores; benchmark gate per phase; zonk memoization |
| Let-boundary re-linking subtlety | Medium | §6.4 dedicated design + test batch before Phase 3 |
| Second solver client destabilizes typechecker refactoring (Design B in flight) | Medium | Phase 1 API is additive wrappers only; coordinate landing order |
| Error-path poisoning corrupts a store mid-item | Low | Fresh store per item; crash-on-mismatch policy |
| Shadow-implementation drift (the MonoDirect failure mode) | High if ignored | Strangler inside production pass; no parallel monomorphizer; no skipped gates |

---

## 10. Summary

The proposal's instinct is correct and the codebase is unusually well
prepared for it: the solver is a pure, re-entrant, snapshot-friendly engine
with instantiation and super handling built in; the typed IR carries a total
per-node type view keyed by an identity space that already mirrors the
solver's union-find roots; and the monomorphizer's worklist is itself the
instantiation mechanism that the failed snapshot architecture lacked. The
right formulation is narrower than "re-run type checking" and different from
the previously-attempted "query the frozen snapshot": **share the engine, not
the phase** — fresh per-work-item solver stores loaded from the typed IR,
real unification at the sites mono already knows, and a single
defaulting-at-readback zonk. The gate is small and independently justified
(structural super export, module-scoped roots, two latent bug fixes); the
frontier is kernel-type honesty; the payoff is the deletion of the
monomorphizer's entire shadow type system — the ~3,000 lines where, per the
design-recovery report, essentially all of this pass's seven months of bugs
have lived.
