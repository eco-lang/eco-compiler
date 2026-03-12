# Design Sketch: Reusing HM Solver State for Monomorphization in Eco

**Status:** Idea / Exploration Only  
**Audience:** Future Eco compiler contributors  
**Scope:** High-level architecture and invariants, not API/implementation details
---
## 1. Motivation

Today, Eco’s pipeline roughly does:
1. **HM type checking on Canonical IR** (constraints → solved types)
2. **PostSolve**: walk Canonical, rebuild / fix types for Group‑B expressions, infer kernel types
3. **TypedOptimized**: convert Canonical → TypedOptimized, attaching `Can.Type` to every expression
4. **Monomorphize**: run a separate specialization pass over `TypedOptimized`, using its own `TypeSubst.unify` machinery and `Can.Type` annotations (plus some local unification) to derive `MonoType`.

This has a few downsides:

- The HM solver’s internal state (substitution graph, solved constraints, layout hints) is **discarded**; later passes have to reconstruct bits of it by re‑unifying fully elaborated types.
- Monomorphization has to carry its own unifier (`TypeSubst`) and duplicate some reasoning that the solver already did.
- Certain patterns (e.g. matching call‑site types to polymorphic kernels, higher‑order specializations, record row polymorphism) are trickier because we work from *flattened* `Can.Type` only, not the richer internal representation the solver had while solving.

In contrast, the Roc Rust mono backend keeps:

- the same **IR** (canonical expressions with `Variable` IDs), and
- the same **solver state** (`Subs` graph, layouts),

alive into the monomorphization phase. Monomorphization then:

- temporarily relaxes rigid vars,
- calls back into the existing `unify` routine to match function annotations against requested specialization types,
- asks the solver/layout subsystem for the concrete layouts it needs,
- then rolls back those local mutations.

The goal of this document is to outline what it would look like if Eco moved in that direction: **monomorphization driven by queries into an HM solver snapshot**, instead of a separate, “second” unification world.

This is deliberately high‑level; the actual code paths and APIs are expected to change over time.
---
## 2. Goals and Non‑Goals
### Goals

1. **Reuse HM solver knowledge in later passes**
   - Keep the solver’s substitution / constraint graph (or a snapshot of it) available beyond Canonical type checking.
   - Allow later passes (PostSolve‑equivalent and Monomorphize‑equivalent) to answer type/layout queries by consulting this snapshot instead of reconstructing from scratch.
2. **Simplify monomorphization logic**
   - Replace most of `TypeSubst.unify` / `unifyExtend` logic with calls into the solver snapshot.
   - Reduce the surface area of “second‑system” unification code.

3. **Maintain or improve correctness invariants**
   - Preserve current guarantees (no unresolved `CNumber` at codegen, fully monomorphic specializations, etc.).
   - Ideally, *tighten* some invariants by leaning on the solver’s graph instead of ad‑hoc type rewrites.

4. **Keep the IR story understandable**
   - Even if we query the solver graph, the *external* IRs (Canonical, TypedOptimized, Mono) should remain mostly declarative and independently checkable.
### Non‑Goals (initially)

- **Not** attempting to completely merge all type logic into a single global solver reused everywhere; this is about *querying a frozen snapshot*, not running a global solver during every pass.
- **Not** attempting to eliminate `TypedOptimized` or `Mono` IRs.
- **Not** optimizing for multi‑threaded compilation yet; assume queries are local to one module’s snapshot.
---
## 3. Current Pipeline (Simplified)

Approximate current order:
1. **Parse → Canonical**
2. **Type Solve (HM)** on Canonical
   - Result: canonical AST + `nodeTypes : NodeId -> Can.Type` + internal solver state (currently discarded).
3. **PostSolve**
   - Walk Canonical:
     - Ensure all expressions have concrete types in `nodeTypes`.
     - Infer kernel function types from usage via a one‑way `unifySchemeToType`.
4. **TypedOptimized**
   - Transform Canonical → TypedOptimized, attaching `Can.Type` directly to each node (`TOpt.Expr`).
5. **Monomorphize**
   - Use `TypeSubst.unify` / `unifyExtend` over `Can.Type`/`MonoType` to specialize functions, lambdas, kernels.
6. **Mono IR → MLIR / backend**

The key point: **HM’s internal substitution graph is not a first‑class artifact** for later passes; only the `Can.Type` “view” is.
---
## 4. Proposed High‑Level Refactor

At a high level:
1. **Keep the HM solver state** as a **snapshot** associated with each module.
2. Replace **PostSolve** with a phase that:
   - primarily *extracts* types from the solver snapshot as needed,
   - potentially annotates Canonical with explicit `Can.Type` where we want a stable, explicit view,
   - defines a unified “query API” for later passes.
3. Replace most of the current **Monomorphize** logic with a new monomorphizer that:
   - operates over either Canonical or TypedOptimized,
   - but when it needs to specialize a function, lambda, record accessor, or kernel, it:
     - relaxes rigids (locally),
     - re‑runs unification against a concrete specialization type,
     - queries layout/representation information from the solver snapshot.

4. Reconsider **TypedOptimized** placement:
   - Option A: Keep its current position (after “PostSolve 2.0”) but allow it to carry *handles* back to solver state (e.g. `VarId`s or `TypeVarId`s).
   - Option B: Move `TypedOptimized` lower, so monomorphization happens still “near” Canonical and its solver graph, then run typed optimization on monomorphic IR. This is more intrusive.

This design doc assumes **Option A** as a starting point: still do Canonical → TypedOptimized before monomorphization, but keep enough IDs / handles in TypedOptimized to map back to the solver snapshot.
---
## 5. HM Solver Snapshot
### 5.1. What we keep

For each module, we persist a **SolverSnapshot** after type solving:
- The substitution / equivalence graph for type variables and type constructors.
- Any solved constraints relevant to representation (numeric vs boxed, record row information, lambda sets if applicable).
- A mapping from:
  - Canonical expression / declaration IDs → type variable IDs,
  - Canonical function annotations → their root type variable IDs.
- Any layout metadata precomputed by the solver (if it already computes some raw layouts, like Roc’s `raw_from_var`).

The snapshot is **immutable** once produced. Later passes may:

- Ask it to **answer queries**,
- Ask it to **temporarily extend** unification locally (with rollback),
- But they do not mutate the “base” snapshot that other passes rely on.
### 5.2. Required operations (conceptual)

Define a module‑local interface:
- `lookupTypeVarOfExpr : ExprId -> TypeVarId`
- `lookupAnnotationVarOfDef : DefId -> TypeVarId`
- `typeOfVar : TypeVarId -> CanonicalTypeView`
  - Returns a `Can.Type` or similar exported view, derived from the solver’s graph.
- `rawLayoutOfVar : TypeVarId -> RawLayout`
  - For monomorphization / backend, similar to `raw_from_var` in Roc.

For local specialization/unification:

- `withTemporaryUnification (rigidRoots : List TypeVarId, unifyPairs : List (TypeVarId, TypeVarId)) (k : LocalSolverView -> a) -> a`
  - Makes rigids under these roots flexible.
  - Applies additional `unify` calls between pairs (e.g. `annotationVar` and `fnVar`).
  - Exposes a `LocalSolverView` where further type and layout queries see the effects.
  - Automatically rolls back to the snapshot when `k` returns.

This is the **general pattern** used by Roc’s mono backend: make rigids flexible, unify annotation with requested specialization variable, query layouts, then rollback.

We don’t prescribe the exact types/names; what matters is the pattern.
---
## 6. Replacing PostSolve

The current `PostSolve` does two core jobs:
1. Ensure certain “Group B” expressions have concretized types in `nodeTypes`.
2. Infer kernel function types from usage (using a one‑way unifier over `Can.Type`).

In a solver‑snapshot world, those responsibilities mostly become queries:
### 6.1. Type extraction phase (PostSolve 2.0)

Instead of walking Canonical to *repair* `nodeTypes`, we:
- Assume the solver snapshot is the **source of truth** for expression/definition types.
- Provide helpers to:
  - Attach explicit `Can.Type` to Canonical nodes where we want stable annotations (e.g. for TypedOptimized),
  - Or allow later passes to query the snapshot directly by `ExprId` / `DefId` / `TypeVarId`.

PostSolve becomes lighter:

- It might:
  - Normalize some alias representations,
  - Seed kernel type info into a dedicated environment by querying solver types for known kernel symbols,
  - Record any per‑module metadata needed for TypedOptimized / Kernels.
- It should not need its own “mini-unifier” like `unifySchemeToType`; instead, it uses the snapshot’s one-way query APIs.
### 6.2. Kernel type inference

Instead of:
- Tracking `(home, name)` → `Can.Type` purely from Canonical + ad‑hoc unification,

PostSolve 2.0 can:

- For each kernel usage site:
  - Use the solver snapshot to get the type variable ID for the call or alias,
  - Ask `typeOfVar` for its canonical type,
  - Or, if needed, use `withTemporaryUnification` to unify it with concrete argument/result variables and then ask for the fully instantiated type.

This keeps all “type arithmetic” in one place: the unified solver.
---
## 7. Replacing Monomorphization

We want monomorphization to more closely mirror Roc’s Rust mono backend, but over Eco’s IRs.
### 7.1. Entry points

Monomorphization remains a worklist‑driven pass:
- Seed with:
  - Host‑exposed functions,
  - `main`, etc.
- For each specialization request:
  - A **global name or lambda ID**,
  - A **requested concrete type** (expressed as `MonoType` or as a root `TypeVarId` + representation mode).

The key change: **how we derive a substitution / layout from that requested type**.
### 7.2. Specializing a top-level function

Today, we do:
- `subst0 = TypeSubst.unify canType requestedMonoType`
- `subst1 = TypeSubst.unifyExtend bodyType requestedMonoType subst0`
- Then `TypeSubst.applySubst` to get parameter/result `MonoType`s.

With a solver snapshot we instead:

1. Identify:
   - `annotationVar : TypeVarId` for the function’s annotated type.
   - `fnVar : TypeVarId` for the requested specialization key (either:
     - from a canonical `Can.Type` → fresh var plus unification, or
     - from a known `TypeVarId` for a call expression).
2. Run:
   ```text
   withTemporaryUnification
       [annotationVar]           -- roots under which to relax rigids
       [(annotationVar, fnVar)]  -- unify annotation with requested type
       (\localView -> ...build specialized proc...)
   ```

3. Inside `localView`:
   - Ask `rawLayoutOfVar` for:
     - function argument layouts,
     - result layout,
     - any lambda set / closure representation info.
   - Ask `typeOfVar` for bodies, nested lambdas, etc., when building `MonoType`s.
4. Build the monomorphized node (`MonoNode` / `Proc`) using this layout and type info.
We no longer need a separate `TypeSubst.Substitution` table for monomorphization; the solver snapshot + temporary unification perform that role.
### 7.3. Lambdas and nested functions

Today we:
- Use `TypeSubst.applySubst` to get a concrete function type from `Can.Type`.
- Use `TypeSubst.unifyExtend` to propagate constraints from enclosing context into internal TVars.

In the snapshot world:

1. Each lambda carries an associated `TypeVarId` or annotation ID (as part of Canonical or carried into TypedOptimized).
2. When specializing a lambda under a given context, we:
   - Identify `lambdaVar : TypeVarId`.
   - Possibly know the expected concrete function type from context (e.g. call‑site).
   - Use `withTemporaryUnification` to:
     - unify `lambdaVar` with the expected type var (if available),
     - then query `typeOfVar` and `rawLayoutOfVar` for parameter/result types.
3. When a nested lambda’s internal TVars need to be specialized, we simply follow their `TypeVarId`s and query the snapshot from the same local view.

This replaces `unifyExtend` and ensures the propagation of constraints is handled by the same HM machinery that originally solved them.
### 7.4. Record accessors and row polymorphism

Today we do ad‑hoc logic to:
- Unify `{ ext | name : T }` with concrete record types using `TypeSubst.unify`.

With a solver snapshot:

- The row polymorphism is already represented at the constraint level in the solver.
- For an accessor `.name`, we:
  - Identify its scheme `TypeVarId`.
  - At a call site, identify the record argument’s `TypeVarId`.
  - In a temporary unification scope, unify accessor’s record input var with the argument’s var.
  - Ask for the **full record layout** from `rawLayoutOfVar`.

This should naturally give complete record shapes at specialization time, mirroring Roc’s approach.
### 7.5. Kernels and constrained variables (`CNumber`, `CEcoValue`)

Today we:
- Use `TypeSubst.unify` to drive numeric specialization and `forceCNumberToInt` to default unresolved numeric TVars.
- Use `CEcoValue` and `MErased` to handle layout‑irrelevant polymorphism in kernels.

With a solver snapshot:

- Numeric constraints (`CNumber` vs `CEcoValue`) live in the solver graph.
- When specializing a kernel:
  - We temporarily unify the kernel’s type variable with the call‑site type variables.
  - Query the numeric constraints; if they are fully resolved to `Int` or `Float`, we generate specialized intrinsics layouts.
  - For unresolved `CNumber` that remain genuinely ambiguous, we can still apply a default (e.g. `Int`) in a controlled fashion, but this defaulting logic lives in a thin shim atop solver queries rather than ad‑hoc `forceCNumberToInt` calls.

We’d need to decide whether to continue exposing `MonoType.MVar CNumber/CEcoValue` to downstream passes, or to always fully monomorphize them away via solver queries.
---
## 8. Interaction with TypedOptimized

This is the main structural question.
### Option A: Keep TypedOptimized before Monomorphize

- **Canonical → HM solve → SolverSnapshot → TypedOptimized → Monomorphize → Mono**
- Requirements:
  - TypedOptimized nodes need to retain **stable IDs** that can be mapped back to the solver snapshot:
    - either original Canonical `ExprId`s / `NodeId`s,
    - or explicit `TypeVarId`s attached to each TypedOptimized node.
  - Monomorphize operates over TypedOptimized but, when it needs type info, goes through:
    - `ExprId -> TypeVarId` mapping,
    - then queries the solver snapshot.
Pros:
- Minimizes disruption to current TypedOptimized and local optimization passes.
- Monomorphizer can still exploit typed‑local optimizations, decision‑tree transforms, etc. before specialization.

Cons:

- TypedOptimized must maintain a robust mapping back to the solver state. This may require extra bookkeeping through all TypedOptimized transformations.
- The solver snapshot must be designed to outlive Canonical and remain addressable from later IRs.
### Option B: Move Monomorphize closer to Canonical (before TypedOptimized)

- **Canonical → HM solve → SolverSnapshot → Monomorphize → Mono → TypedOpt‑like optimization on Mono**
- TypedOptimized would either:
  - Move “below” monomorphization as an optimization pass on Mono, or
  - Be partially subsumed by monomorphization and Mono optimization.
Pros:
- Monomorphizer operates directly on Canonical + solver snapshot (similar to Roc’s Rust backend).
- No need to maintain a cross‑IR mapping for types.

Cons:

- Very disruptive to existing TypedOptimized code and its invariants.
- Requires re‑implementing or porting typed optimizations (inlining, decision trees, etc.) to work on Mono instead of TOpt.
- Much riskier as a refactor.

**Recommendation for now:** Keep Option A as the target; capture Option B as a hypothetical longer‑term redesign.
---
## 9. Migration Strategy (Conceptual)

This is not a concrete plan, but a rough staging to make this incremental:
1. **Introduce SolverSnapshot data structure**
   - After HM solve, snapshot the substitution graph and any necessary metadata.
   - Keep existing PostSolve and Monomorphize unchanged at first; they continue to use `Can.Type` only.

2. **Add query APIs**
   - Implement `typeOfVar`, `rawLayoutOfVar`, and basic `withTemporaryUnification`.
   - Write internal tests that compare:
     - `typeOfVar` vs existing `nodeTypes` / annotations,
     - `rawLayoutOfVar` vs current layout computations, to ensure they’re equivalent.

3. **Refactor PostSolve to use SolverSnapshot**
   - Replace its internal `unifySchemeToType` with calls into `withTemporaryUnification`.
   - Gradually move “type repair” logic to snapshot queries.

4. **Pilot a new, *parallel* monomorphizer**
   - Implement a simplified specialization path that:
     - For a small subset of constructs (e.g. top‑level `Define`s without higher‑order), uses solver snapshot queries instead of `TypeSubst`.
   - Compare its output Mono graphs to the existing monomorphizer on test programs.

5. **Expand coverage**
   - Add support for lambdas, accessors, kernels, and record row polymorphism.
   - Once the new monomorphizer is feature‑complete and passes invariants, retire `TypeSubst.unify`/`unifyExtend` from the main path.

6. **Tighten invariants**
   - Update monomorphization and codegen invariants to reflect the new source of truth being the solver snapshot.
   - Remove duplicated or now‑redundant type computation code paths.
---
## 10. Risks and Open Questions

1. **Lifetime and size of solver snapshots**
   - Holding the full solver graph around for each module may have non‑trivial memory cost.
   - Mitigation: design snapshot as a compact, persistent structure; possibly compress type equivalence classes.
2. **Concurrency / parallel compilation**
   - If we later want to compile modules in parallel, we must ensure snapshots are immutable and independently queryable.
   - The `withTemporaryUnification` pattern must be strictly local (no shared mutable global solver).

3. **Mapping across IRs**
   - Under Option A, TypedOptimized must preserve enough identity to map back to solver variables.
   - We need a robust story for:
     - expression ID remapping,
     - how inlining / DCE / decision‑tree transforms affect type variable associations.

4. **Complexity of local unification**
   - Even though we reuse the HM solver’s core unifier, adding “local re‑unify with rollback” may complicate solver code.
   - Clear separation between:
     - “full program solve” phase, and
     - “snapshot + local unify” queries is crucial.

5. **Interaction with existing invariants**
   - Many monomorphization invariants (e.g. no `CNumber` at codegen, complete record layouts, etc.) assume a `MonoType`‑driven substitution world.
   - We must ensure that replacing `TypeSubst` with solver queries preserves or strengthens these invariants.

6. **Future direction for TypedOptimized**
   - Long‑term, if we find typed optimization is easier on Mono than on TOpt, we might revisit Option B (moving TypedOptimized below monomorphization).
   - That would be another major design exercise.
---
## 11. Summary

This document sketches a possible future refactor where Eco:
- **runs HM once** on Canonical,
- **keeps the solver state** as a snapshot,
- **replaces PostSolve** with a query‑oriented phase into that snapshot, and
- **replaces most of Monomorphize** with a specialization pass that:
  - relaxes rigid vars locally,
  - re‑invokes the solver’s unifier in a constrained scope,
  - queries layout and type information for specialization, then rolls back.

The key benefits are:

- Less duplicated unification logic,
- A single, authoritative source of truth for types and constraints,
- Potentially simpler and more robust monomorphization for complex polymorphic patterns.

The costs are:

- Re‑architecting how type information flows between Canonical, TypedOptimized, and Mono,
- Designing a robust snapshot and query API,
- Carefully migrating existing passes and invariants.

This is intended as a **high‑level roadmap**, not an implementation plan; details will likely need to evolve with the compiler’s codebase.

# Appendix: Invariants Delta for Solver‑Snapshot–Driven Monomorphization

This appendix records how the proposed “HM solver snapshot + query‑driven monomorphization” design would affect existing invariants, and which new invariants it would introduce.
It is intentionally high‑level and forward‑looking; actual test logic and IDs would need to be updated once the refactor is real.
---
## A.1 Overview

**Unaffected invariants (conceptually):**
- All **representation** and backend invariants:  
  `REP_*`, `REP_ABI_*`, `REP_SSA_*`, `REP_HEAP_*`, `REP_BOUNDARY_*`, `REP_CLOSURE_*`, `REP_CONSTANT_*`.
- Canonicalization and type checking correctness:  
  `CANON_*`, `TYPE_*`, `NITPICK_*`.
- Typed optimization invariants that only talk about `Can.Type` being attached to `TypedOptimized` and preserved:  
  `TOPT_001–TOPT_005`.
- Most monomorphization/GlobalOpt/MLIR/Heap/BytesFusion invariants whose statements are about **Mono**, layouts, MLIR, heap, or fusion behavior, not how types or substitutions are computed:  
  `MONO_001–007`, `MONO_009–019`, `MONO_022–023`, `GOPT_*`, `CGEN_*`, `HEAP_*`, `BFUSE_*`, `BFOPS_*`, `XPHASE_*`, `FORBID_*`.

These invariants are below the level where the solver snapshot vs. `TypeSubst` implementation detail matters; the new design is intended to preserve them.

The main impact is on:

- **PostSolve invariants** `POST_001–POST_009`  
- A subset of **Monomorphization invariants** that talk explicitly about how specialization substitutions are derived:  
  `MONO_008`, `MONO_015`, `MONO_020–MONO_021`, `MONO_024–MONO_025`
- Some **cross‑phase assumptions** about where “fixed types” come from (NodeTypes vs solver snapshot).
---
## A.2 Existing Invariants That Change or Are Superseded
### A.2.1 PostSolve (`POST_*`)

**Current role:** PostSolve “repairs” types after solving by structurally filling in Group B expressions, inferring kernel types, and ensuring `NodeTypes` is suitable for TypedCanonical / TypedOptimized / Monomorphize.
Under the new design, PostSolve becomes mostly an **extraction layer** over the solver snapshot rather than a actively mutating `NodeTypes`. That alters several invariants:
---

**POST_001;PostSolve;GroupB;enforced**
> assigns structurally computed types to all Group B expressions whose solver types were unconstrained synthetic variables …
- **Impact:**  
  - Semantics (“Group B expressions have concrete structural types”) should remain.
  - **Mechanism changes**: instead of computing new structural `Can.Type`s independently, PostSolve 2.0 will *ask the solver snapshot* for each Group B node’s type or derive it via snapshot queries.
- **Status:**  
  - **Reword as POST2_001**: “All Group B expressions have concrete structural types derived from the HM solver snapshot (possibly via local unification queries), not from ad‑hoc post‑hoc reconstruction.”
---

**POST_002;PostSolve;KernelTypes;documented**
> kernel types inferred via seeding + one‑way scheme‑to‑type unification …
- **Impact:**  
  - High‑level behavior (build `KernelTypeEnv` with first‑usage‑wins) remains.
  - Implementation will use solver snapshot queries plus local `withTemporaryUnification` instead of its own `unifySchemeToType`.
- **Status:**  
  - **Keep semantically**, but update source to “SolverSnapshot+PostSolve2” rather than the bespoke PostSolve unifier.
---

**POST_003;PostSolve;GroupBCompleteness;enforced**
> After PostSolve all non‑negative expression IDs in NodeTypes have meaningful concrete types …
- **Impact:**  
  - Still desired: NodeTypes (or equivalent typed view) must be complete.
  - But “concreteness” now comes directly from solver snapshot + extraction, not from PostSolve inventing types.
- **Status:**  
  - **Keep**, but clarify that `NodeTypes` is a *view of the snapshot* rather than a separately mutated map.
---

**POST_004;PostSolve;Determinism;documented**  
- Stated determinism still holds; the snapshot is deterministic for a given Canonical+constraints, and extraction is pure.
- **Status:** Keep, but reword to emphasize determinism flows from the solver snapshot.
---

**POST_005;PostSolve;NonRegressionStructuredNodeTypes;enforced**
> For nodes whose solver type is not bare `TVar`, PostSolve must not change that node type …
- **Impact:**  
  - If PostSolve 2.0 stops *mutating* `NodeTypes` for non‑Group‑B nodes, this invariant becomes trivially true.
  - Conceptually, NodeTypes is now *computed from* the solver graph; no “change” happens.
- **Status:**  
  - Either keep as a sanity check (“extraction never contradicts the snapshot”), or **mark as subsumed** by the new snapshot invariants (see SNAP_003 below).
---

**POST_006;PostSolve;NoNewFreeTypeVars;enforced**
> PostSolve does not introduce new free TVars …
- **Impact:**  
  - If we no longer invent PostSolve‑only TVars, this is also trivially satisfied.
- **Status:**  
  - Could be retained but now states a stronger property: extraction *never* invents new TVars at all.
  - Ties into a new invariant that “all TVars originate from the HM solver or user annotations.”
---

**POST_007;PostSolve;LambdasStructuralTypes;documented**
> PostSolve constructs TLambda chains for Group B lambdas when the solver left them as bare TVars …
- **Impact:**  
  - Under a snapshot design, the *preference* is to have the solver itself (or constraint generation) produce usable lambda types, rather than patching them post‑hoc.
  - If we still need structural repair, we can do it via snapshot queries, but we’ll probably want to reduce reliance on PostSolve‑only lambda placeholders.
- **Status:**  
  - Likely **reworded or weakened**; we may prefer a new invariant that either:
    - (a) solver ensures lambdas never remain bare TVars, or
    - (b) any structural repair is done via the snapshot and does not invent solver‑invisible placeholders.
---

**POST_008;PostSolve;LambdasContextVars;documented**
> PostSolve must not introduce unconstrained lambda‑local TVars …
- **Impact:**  
  - If we stop inventing new lambda TVars, this invariant remains, but becomes a property of the solver snapshot and extraction (no invented vars).
- **Status:** Keep, but re‑anchor its justification in “no new TVars beyond snapshot/annotations.”
---

**POST_009;PostSolve;Placeholders;documented**
> PostSolve‑generated placeholder TVars must not appear in function positions …
- **Impact:**  
  - Ideally, the new design **eliminates** the whole notion of “PostSolve‑generated placeholder TVars”.
- **Status:**  
  - **Superseded** by new snapshot invariants that forbid PostSolve‑only TVars entirely (see SNAP_004).
---
### A.2.2 Monomorphization invariants (`MONO_*`)

Most `MONO_*` invariants are about the **shape of Mono**, layouts, and reachability, and remain valid regardless of whether types came from `TypeSubst` or solver queries.
The ones that need rephrasing are those that talk explicitly about *how* we unify types and derive substitutions:
---

**MONO_008;Monomorphization;Types;enforced**
> Function call specialization **unifies canonical function types with monomorphic argument types** so numeric types are fixed to `MInt`/`MFloat` and mismatches are bugs.
- **Impact:**  
  - Semantics unchanged: we still unify function types with argument types at specialization time and fix numeric polymorphism.
  - Mechanism changes: unification is performed inside the HM solver snapshot (temporary scope) rather than via `TypeSubst.unify`.
- **Status:**  
  - **Keep**, but replace “unifies canonical function types …” with “unifies the callee’s solver type variables with the argument solver type variables in a local solver scope.”
---

**MONO_015;Monomorphization;Accessors;enforced**
> Accessor extension variables are unified with full record type so specialization receives complete record layout; currently attributed to `TypeSubst`.
- **Impact:**  
  - Semantics (accessors see full record layout) remains.
  - Implementation: we would use solver snapshot unification between accessor’s scheme var and record arg var.
- **Status:**  
  - **Keep**, but update `source` to the new monomorphization code path and refer to “solver snapshot unification” instead of `TypeSubst`.
---

**MONO_020;Monomorphization;Let-Bound Functions;documented**
> All reachable non‑kernel user‑defined functions have no `CEcoValue` in MFunction param/result positions, enforced via `collectLocalCallSubst` and call‑site substitution.
- **Impact:**  
  - Semantics (“no CEcoValue in fully monomorphic function types”) is still desired.
  - Mechanism of “substitution from call sites” will now be described as “specialization key + solver snapshot unification” rather than build‑it‑yourself `Substitution`.
- **Status:**  
  - **Keep semantics**, but rephrase so the “monomorphization substitution” is defined as “the substitution induced by the solver snapshot in the specialization’s temporary unification scope.”
---

**MONO_021;Monomorphization;Types;documented**
> At MLIR entry, reachable non‑kernel user functions have no `CEcoValue`/`MErased` in function param/result; ties to specialization substitution and pruning.
- **Impact:**  
  - Still valid.
  - Needs its explanatory text updated to say “failed to propagate concrete types out of solver snapshot” rather than “failed to apply monomorphization `Substitution`.”
- **Status:** Keep, reworded.
---

**MONO_024;Monomorphization;Types;documented**
> For specializations whose key MonoType is fully monomorphic, **the entire reachable expression tree contains no CEcoValue MVar**; any such indicates “failure to propagate concrete type from specialization key into implementing node’s types.”
- **Impact:**  
  - The idea that “keys and implementing nodes agree, and concrete keys do not leave CEcoValue residue” still stands.
  - Explanation should be updated: the failure would be “failure to fully propagate solver‑snapshot unification results into all MonoTypes of that specialization.”
- **Status:** Keep, but redefine the notion of “specialization substitution” to be “solver snapshot local unification result.”
---

**MONO_025;Monomorphization;Closures;documented**
> Closure’s stored MonoType must be consistent with its specialization key; currently described in terms of “monomorphization substitution used for that specialization.”
- **Impact:**  
  - Again, semantics unchanged.
  - We just define the substitution as coming from the solver snapshot’s local unification scope.
- **Status:** Keep, update explanation accordingly.
---
### A.2.3 Cross‑phase assumptions

A few invariants implicitly assume that **NodeTypes after PostSolve** is the ultimate source of truth:
- `TOPT_003`, `TOPT_004` refer to `nodeTypes` and `TypedCanonical` as the type source.
- `XPHASE_011` talks about MonoTypes preservation between Monomorphize and GlobalOpt; no change.
- `POST_003` already discussed.

Under the new design:

- These invariants should be interpreted as:  
  “`nodeTypes` (or equivalent) is a *faithful view* of the HM solver snapshot at the time of PostSolve 2.0.”
- We may add explicit new invariants tying `nodeTypes` to the snapshot, rather than to PostSolve’s ad‑hoc repairs.
---
## A.3 New Invariants Introduced by the Design

Below are **proposed** new invariants in the existing format. Names/IDs are placeholders; final IDs can be chosen when/if the refactor happens.
### A.3.1 Solver snapshot invariants
---

**SNAP_001;TypeChecking;SolverSnapshot;documented**
> After HM constraint solving completes for a module, the compiler constructs a SolverSnapshot that captures:
> - the union‑find equivalence classes for all type variables,
> - solved constraints relevant to representation and layouts (including numeric/boxed distinctions and record rows),
> - mappings from canonical Expr/Def IDs to root type variables.
> The SolverSnapshot is immutable and is the single source of truth for all later type queries.
---

**SNAP_002;TypeChecking;SolverSnapshot;enforced**
> All post‑solve phases (PostSolve 2.0, TypedOptimized, Monomorphize, GlobalOpt, MLIR codegen) treat the SolverSnapshot as read‑only; they may not mutate its equivalence classes or constraints. Any local unification after solve must occur in a temporary view layered on top of the snapshot.
---

**SNAP_003;TypeChecking;LocalUnification;enforced**
> Any phase that needs additional unification after global solve (e.g. specialization) must use a `withTemporaryUnification`‑style API:
> - temporarily relax rigid variables under specified roots,
> - apply a finite list of extra unification equations (e.g. annotationVar == fnVar),
> - query resulting types/layouts,
> - then roll back to the original snapshot.  
> No additional equalities may be committed globally after the HM solve step.
---

**SNAP_004;TypeChecking;NoPostSolveTVars;enforced**
> No phase after HM solving may introduce new canonical type variables that are not present in either:
> - the original constraint graph (solver’s TVars), or
> - user‑provided type annotations.  
> PostSolve 2.0 and TypedOptimized may not invent “placeholder” TVars; all lambda and Group B types must be expressed purely in terms of the solver snapshot and annotations.
---
### A.3.2 PostSolve 2.0 invariants
---

**POST2_001;PostSolve2;ExtractionOnly;documented**
> PostSolve 2.0 does not change the HM solver’s notion of types. For every non‑negative expression/pattern ID that had a concrete type in the snapshot, the type recorded in NodeTypes (or TypedCanonical) is alpha‑equivalent to the snapshot’s exported `Can.Type` view.
---

**POST2_002;PostSolve2;GroupBCompleteness;enforced**
> For all Group B expressions (lists, tuples, records, units, lambdas) whose solver snapshot types would otherwise be unconstrained, PostSolve 2.0 must either:
> - extract a fully structural type from solver context, or
> - insert a deterministic, purely structural type that is compatible with the snapshot’s constraints.  
> After PostSolve 2.0, no Group B expression remains with a bare unconstrained TVar in NodeTypes.
---

**POST2_003;PostSolve2;KernelTypesFromSnapshot;documented**
> KernelTypeEnv is derived from the SolverSnapshot by querying types of alias bodies and call sites (possibly under local unification), rather than by an independent scheme‑to‑type unifier. First‑usage‑wins semantics remain unchanged.
---
### A.3.3 Monomorphization + snapshot invariants
---

**MONO_SNAP_001;Monomorphization;SnapshotSource;documented**
> All monomorphization decisions (which specializations to create, how to instantiate type variables, which record/tuple/custom layouts to use) are derived from the HM SolverSnapshot plus local temporary unification scopes. No parallel type‑substitution engine (`TypeSubst`) may disagree with the snapshot; if present, it must be a pure view of snapshot state.
---

**MONO_SNAP_002;Monomorphization;LocalScope;enforced**
> For each specialization (identified by Global, MonoType key, and optional LambdaId), the substitution from canonical types to MonoTypes is exactly the mapping induced by a local unification scope in the SolverSnapshot where:
> - the function’s annotation variable is unified with the specialization key’s type variable,
> - any required call‑site or contextual equalities are applied,
> - layouts for arguments, results, captures, and record fields are obtained from snapshot‑derived layouts.  
> No specialization may use a substitution that is not obtainable in this way.
---

**MONO_SNAP_003;Monomorphization;NoDivergenceFromSnapshot;enforced**
> For every reachable specialization, reconstructing canonical function types from MonoTypes and then projecting back into the SolverSnapshot must yield types compatible with the snapshot’s equivalence classes. Any divergence (e.g. MonoType suggesting `Int` where snapshot types constrain to `Float`) is a monomorphization bug.
---

**MONO_SNAP_004;Monomorphization;AccessorLayouts;documented**
> When specializing accessors, the record layouts used in Mono must come from SolverSnapshot unification of accessor scheme and call‑site record types. Mono may not construct partial record layouts by syntactic inspection of `Can.Type` alone.
---
### A.3.4 Cross‑phase mapping invariants

To support Option A (TypedOptimized before Monomorphize), we need explicit guarantees that we can still get from TOpt nodes back to solver types.
---

**XSNAP_001;CrossPhase;TypeVarMapping;documented**
> Every TypedOptimized expression that may participate in monomorphization retains a stable mapping to the corresponding solver type variable:
> - either by carrying its original Canonical `ExprId`/`NodeId`, or
> - by carrying an explicit `TypeVarId` from the SolverSnapshot.  
> Typed optimization passes must preserve this mapping through inlining, DCE, and decision‑tree transforms.
---

**XSNAP_002;CrossPhase;SnapshotConsistency;tested**
> For any TypedOptimized.Expr `e`:
> - `TOpt.typeOf e` (its attached `Can.Type`) is alpha‑equivalent to `typeOfVar (lookupTypeVarOfExpr e)` as exported from the SolverSnapshot, up to PostSolve 2.0’s structural repair for Group B expressions.  
> This ensures TOpt’s `Can.Type` view never drifts from the snapshot.
---
## A.4 Summary

- Most invariants in the current system **survive unchanged**, especially all representation, MLIR, heap, and bytes fusion invariants.
- The main changes are:
  - PostSolve becomes extraction‑oriented; invariants about it “repairing” types need to be reframed as “faithful views of the solver snapshot.”
  - Monomorphization invariants that mention “monomorphization substitution” need to reinterpret that substitution as the result of **local unification inside a solver snapshot**, rather than a separate `TypeSubst` engine.
- New invariants (`SNAP_*`, `POST2_*`, `MONO_SNAP_*`, `XSNAP_*`) codify:
  - the existence and immutability of the solver snapshot,
  - the discipline around temporary unification + rollback,
  - the requirement that later IRs (TypedOptimized, Mono) stay in lockstep with the snapshot’s notion of types and layouts.
This appendix should be treated as a constraints checklist when/if a future refactor attempts to implement solver‑snapshot‑driven monomorphization.
