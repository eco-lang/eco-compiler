# Plan: Solver-Backed MonoDirect Specialization (Eliminate TypeSubst Fallback)

## Goal

Make MonoDirect purely solver-backed for all real specializations. Eliminate the "empty unification / TypeSubst" fallback in `specializeDefineNode` and `resolveType` that produces CEcoValue/MErased leakage.

**Core principle:** If a node is polymorphic, it MUST have a solver variable. Missing tvars on polymorphic nodes are bugs, not cases to recover from.

---

## Current State Analysis

### The Problem

1. **`specializeDefineNode` (Specialize.elm:114-137)**: When `meta.tvar = Nothing`, falls back to `withLocalUnification snapshot [] []` — an empty unification context that cannot push concrete types through polymorphic bodies.

2. **`resolveType` (Specialize.elm:171-180)**: When `meta.tvar = Nothing`, falls back to `KernelAbi.canTypeToMonoType_preserveVars meta.tipe`. If `meta.tipe` still contains TVars, this produces CEcoValue/MErased.

3. **`specializePortNode` (Specialize.elm:141-162)**: When `meta.tvar = Nothing`, returns `MonoUnit` — a silent loss of port implementation.

### Root Cause: Missing tvars on Function Definitions

In `Module.elm:469-480`, function definitions with arguments get `nodeTvar = Nothing`:
```elm
nodeTvar =
    case args of
        [] -> bodyTvar    -- OK: value def, body tvar IS the def tvar
        _  -> Nothing     -- PROBLEM: body tvar is only the return type
```

The comment says "no single solver variable exists for the overall function type." This is the fundamental gap: the constraint generator records solver variables per-expression (`ExprVars`), but a function definition's full type (`a -> b -> c`) doesn't correspond to a single expression with an ID in `nodeVars`.

**Why NodeIds can't help:** `constrainDefWithIds` for `Can.Def`/`Can.TypedDef` constructs a `TypedArgs` with `tipe = full function type` and emits a `CLet` header `name : tipe` into the constraint tree. But no `NodeIds.recordNodeVar` is called for the function's annotation — `NodeIds` is only used for expression and pattern IDs.

**Where the annotation variable actually lives:** The canonical, single HM variable for the function as a value lives in the solver's `Env`. `CLocal`/`CForeign` constraints refer to names in `Env`, and `Type.toAnnotation` converts each `Env` entry (a `Variable`) into a `Can.Annotation`.

### What Already Works

- `nodeVars` from `Solve.runWithIds` IS the same `ExprVars` array passed to LocalOpt (confirmed: created in constraint generation, passed unchanged).
- `SolverSnapshot.specializeFunction` correctly walks+unifies a type variable against a `MonoType`.
- Value definitions (no args) already get `bodyTvar` correctly.
- TypeSubst is NOT directly imported in MonoDirect modules (only referenced in comments). The actual fallback uses `SolverSnapshot.withLocalUnification [] []` which internally uses `TypeSubst.canTypeToMonoType` in `buildLocalView`.

---

## Implementation Plan

### Phase 1: Expose Annotation Variables from the Solver (Option D)

**Approach:** Extend `Solve.runWithIds` to surface the solver `Env` (or a filtered `annotationVars` view) alongside `annotations`, `nodeTypes`, and `nodeVars`. This is the Roc-analogous approach — every definition gets a `Variable` handle from the HM environment, not from expression IDs.

**Step 1.1: Extend `Solve.runWithIds` return type**

File: `compiler/src/Compiler/Type/Solve.elm`

Add `annotationVars : Dict String Name.Name IO.Variable` to the result record:

```elm
runWithIds :
    Constraint
    -> Array (Maybe Variable)
    -> IO (Result (NE.Nonempty Error.Error)
           { annotations    : Dict String Name.Name Can.Annotation
           , annotationVars : Dict String Name.Name IO.Variable  -- NEW
           , nodeTypes      : Array (Maybe Can.Type)
           , nodeVars       : Array (Maybe Variable)
           , solverState    : SolverState
           })
```

Implementation: In `solve`, we already have `Env` when we reach the final `State env mark errors`. `Type.toAnnotation` is currently called on each `Variable` in `env` to produce `annotations`. Just also return `env` (or a copy) as `annotationVars` before converting to annotations.

**Step 1.2: Thread `annotationVars` into SolverSnapshot**

File: `compiler/src/Compiler/Type/SolverSnapshot.elm`

Extend `SolverSnapshot` to carry the annotation vars:

```elm
type alias SolverSnapshot =
    { state : SolverState
    , nodeVars : Array (Maybe TypeVar)
    , annotationVars : Dict String Name.Name TypeVar  -- NEW
    }
```

Update `fromSolveResult` to accept and store the new field.

**Step 1.3: Thread `annotationVars` to LocalOpt**

File: `compiler/src/Compiler/Compile.elm` (pipeline), `compiler/src/Compiler/LocalOpt/Typed/Module.elm`

- Pass the `annotationVars` dict through the pipeline from `typeCheckTyped` → `typedOptimizeFromTyped` → `optimizeTyped`.
- In `optimizeTyped`, make it available to `addDefNode`.

**Step 1.4: Wire annotation variable into `addDefNode`**

File: `compiler/src/Compiler/LocalOpt/Typed/Module.elm`

Replace the `nodeTvar` logic in `addDefNode` (line 473):

```elm
-- BEFORE:
nodeTvar =
    case args of
        [] -> bodyTvar
        _  -> Nothing

-- AFTER:
nodeTvar =
    case args of
        [] -> bodyTvar
        _  ->
            -- Look up the annotation-level solver variable for this definition
            Dict.get name annotationVars
                |> Maybe.map (\var -> Just var)
                |> Maybe.withDefault bodyTvar
```

For recursive definitions (`addRecDefs`): The same applies. `constrainRecursiveDefsWithIds` builds a `CLet` with function headers for each def in the cycle, so each cycle member gets an annotation-level `Variable` in `Env`. Once we expose `Env`, cycle members get annotation vars the same way as non-recursive defs.

Ensure both `TOpt.TrackedDefine` and the inner `TOpt.TrackedFunction` carry this tvar.

**Step 1.5: Propagate tvar through `wrapDestruct` wrappers**

File: `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`

```elm
-- BEFORE (line 1004-1006):
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr { tipe = bodyType, tvar = Nothing }

-- AFTER:
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr { tipe = bodyType, tvar = TOpt.tvarOf expr }
```

This is correct because the Destruct wrapper's type equals the inner expression's type, so the solver variable is the same. If the inner expression has `tvar = Nothing`, that's a missing-coverage bug that SNAP_TVAR_001 will expose.

**Step 1.6: Leave legitimate `tvar = Nothing` for synthetic/monomorphic nodes**

These are fine and should NOT be changed:
- Record alias constructors (Module.elm:186-200) — synthetic, monomorphic
- Port encoders/decoders (Port.elm) — synthetic, constructed from concrete types
- `VarCycle` references — they reference global defs that carry tvars; the definition nodes carry the solver link
- Case expressions (Case.elm:65) — structural, not specialization roots
- `VarGlobal` in Names.elm — references to globals go through the specialization mechanism, not through `meta.tvar` directly
- `VarDebug` — `Can.VarDebug` does not call `NodeIds.recordNodeVar` in the typed constraint generator; these are never specialization roots (you specialize the function that *contains* them, not the debug intrinsic itself)

---

### Phase 2: Tighten MonoDirect.Specialize

**Execution order decision: Phase 2 FIRST, then fix tvar gaps as crashes surface.**

Since this is a test-only pipeline, the most productive approach is:
1. Implement the stricter `requireTVar` / `isMonomorphicType` checks (this phase)
2. Run the test suite — each crash gives a precise stack + node context where tvar coverage is missing
3. Patch LocalOpt/Solve to propagate tvars there

This moves feedback earlier and removes silent CEcoValue/MErased leakage. It's how the 102 failures were originally identified; turning the fallback into a hard error just makes that systematic.

**Step 2.1: Add `requireTVar` helper**

File: `compiler/src/Compiler/MonoDirect/Specialize.elm`

```elm
requireTVar : String -> TOpt.Meta -> IO.Variable
requireTVar context meta =
    case meta.tvar of
        Just v -> v
        Nothing ->
            Utils.Crash.crash
                ("MonoDirect." ++ context ++ ": missing solver tvar for type "
                    ++ Debug.toString meta.tipe)
```

**Step 2.2: Add `isMonomorphicType` helper**

File: `compiler/src/Compiler/MonoDirect/Specialize.elm`

A recursive check that `Can.Type` contains no `Can.TVar` nodes. Needed for the safe fallback on synthetic nodes.

```elm
isMonomorphicType : Can.Type -> Bool
isMonomorphicType tipe =
    case tipe of
        Can.TVar _ -> False
        Can.TLambda a b -> isMonomorphicType a && isMonomorphicType b
        Can.TType _ _ args -> List.all isMonomorphicType args
        Can.TTuple a b rest -> List.all isMonomorphicType (a :: b :: rest)
        Can.TRecord fields ext ->
            Dict.foldl (\_ (Can.FieldType _ t) ok -> ok && isMonomorphicType t) True fields
                && ext == Nothing
        Can.TAlias _ _ args _ -> List.all (isMonomorphicType << Tuple.second) args
        _ -> True
```

**Step 2.3: Tighten `specializeDefineNode`**

Remove the `Nothing` branch entirely:

```elm
specializeDefineNode snapshot expr meta requestedMonoType state =
    let
        annotVar = requireTVar "specializeDefineNode" meta
    in
    SolverSnapshot.specializeFunction snapshot annotVar requestedMonoType
        (\view ->
            let (monoExpr, state1) = specializeExpr view snapshot expr state
            in (Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), state1))
```

**Step 2.4: Tighten `resolveType`**

Allow monomorphic `Nothing` (safe for synthetic nodes), crash on polymorphic `Nothing`:

```elm
resolveType view meta =
    case meta.tvar of
        Just tvar ->
            Mono.forceCNumberToInt (view.monoTypeOf tvar)
        Nothing ->
            if isMonomorphicType meta.tipe then
                Mono.forceCNumberToInt (KernelAbi.canTypeToMonoType_preserveVars meta.tipe)
            else
                Utils.Crash.crash
                    ("MonoDirect.resolveType: missing solver tvar for polymorphic type "
                        ++ Debug.toString meta.tipe)
```

**Step 2.5: Tighten `specializePortNode`**

Require tvar if polymorphic, allow monomorphic fallback:

```elm
specializePortNode snapshot expr meta requestedMonoType nodeConstructor state =
    case meta.tvar of
        Just annotVar ->
            SolverSnapshot.specializeFunction snapshot annotVar requestedMonoType
                (\view ->
                    let (monoExpr, state1) = specializeExpr view snapshot expr state
                    in (nodeConstructor monoExpr requestedMonoType, state1))
        Nothing ->
            if isMonomorphicType meta.tipe then
                SolverSnapshot.withLocalUnification snapshot [] []
                    (\view ->
                        let (monoExpr, state1) = specializeExpr view snapshot expr state
                        in (nodeConstructor monoExpr requestedMonoType, state1))
            else
                Utils.Crash.crash
                    "MonoDirect.specializePortNode: missing tvar for polymorphic port"
```

---

### Phase 3: Optional Upfront Validation

**Step 3.1: Add `validateSolverCoverage`**

File: `compiler/src/Compiler/MonoDirect/Monomorphize.elm`

Before the worklist loop, validate that all nodes in the global graph satisfy SNAP_TVAR_001: polymorphic nodes must have `meta.tvar = Just _`.

```elm
monomorphizeDirect entryPointName globalTypeEnv snapshot globalGraph =
    case validateSolverCoverage globalGraph of
        Err msg -> Err msg
        Ok () -> -- existing code
```

This catches violations at the earliest point, before any specialization work.

---

### Phase 4: Testing & Migration

**Step 4.1: Run existing tests to find new crashes**

After Phase 2, run `cmake --build build --target check`. The new `requireTVar` / `isMonomorphicType` crashes will pinpoint exactly which definitions are still missing tvars. Each crash gives a precise stack + node context.

**Step 4.2: Fix tvar gaps iteratively**

Each crash will identify a specific code path in LocalOpt or the pipeline that constructs a polymorphic node without a tvar. Fix each one (using the annotation vars from Phase 1) until all tests pass.

**Step 4.3: Verify the three failure categories are resolved**

- **Category 1** (wrong specialization keys): Should now go through `specializeFunction` with proper unification
- **Category 2** (main _tv type MErased): Wrappers propagate tvars, `resolveType` refuses polymorphic Nothing
- **Category 3** (MONO_021 CEcoValue/MErased in user functions): Empty-context fallback eliminated

**Step 4.4: Add invariant test for SNAP_TVAR_001**

Create a test that validates tvar coverage across the global graph for a set of representative programs.

---

## Execution Order

1. **Phase 2.1-2.2** (add `requireTVar` + `isMonomorphicType` helpers)
2. **Phase 2.3-2.5** (tighten Specialize.elm — remove fallbacks)
3. **Phase 1.1-1.2** (expose `annotationVars` from Solve → SolverSnapshot)
4. **Phase 1.3-1.4** (thread to LocalOpt, wire into `addDefNode`)
5. **Phase 1.5** (propagate tvar through `wrapDestruct`)
6. **Phase 3** (upfront validation)
7. **Phase 4** (testing iteration — fix remaining tvar gaps)

Rationale: Tighten Specialize first to get crash-based discovery of missing tvars. Then wire annotation vars through the pipeline to fix the root causes. Each step is independently testable.

---

## New Invariants

### SNAP_TVAR_001: Solver-Backed Specialization Roots

> If a `TOpt.Meta` has a polymorphic `tipe` (contains any `Can.TVar`), then `meta.tvar` must be `Just _` and that variable must appear in the solver snapshot. If this is violated in MonoDirect, the compiler crashes with a clear internal error.

**Exceptions:** Truly monomorphic synthetic nodes (record alias constructors, port helpers built from concrete types, VarCycle references, VarDebug) may have `tvar = Nothing` provided their `tipe` contains no TVars. A small explicit whitelist of leaf-node kinds (VarDebug, some VarKernel) that are never specialization roots may also have `tvar = Nothing` even if polymorphic at the scheme level, since their polymorphism is resolved by the enclosing function's solver context.

### SNAP_TVAR_002: No TypeSubst-Driven Specialization in MonoDirect

> All monomorphization decisions in MonoDirect are derived from the SolverSnapshot. The `specializeDefineNode` function must not have a fallback path that creates substitutions independent of the solver.

**Note on `SolverSnapshot.buildLocalView`:** Its internal use of `TypeSubst.canTypeToMonoType Dict.empty` is acceptable — it's a deterministic projection from a fully-walked solver variable to `MonoType`, not an independent inference engine. It cannot contradict the snapshot because it operates downstream of the solver. This is consistent with the invariant: "if TypeSubst is present, it must be a pure view of snapshot state."

---

## Files Modified

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Type/Solve.elm` | Extend `runWithIds` to return `annotationVars : Dict String Name.Name IO.Variable` from the solver `Env` |
| `compiler/src/Compiler/Type/SolverSnapshot.elm` | Add `annotationVars` field to `SolverSnapshot`, update `fromSolveResult` |
| `compiler/src/Compiler/Compile.elm` | Thread `annotationVars` through the pipeline |
| `compiler/src/Compiler/LocalOpt/Typed/Module.elm` | Accept `annotationVars`, wire into `addDefNode`/`addRecDefs`, replace `nodeTvar` logic |
| `compiler/src/Compiler/LocalOpt/Typed/Expression.elm` | Propagate tvar in `wrapDestruct` |
| `compiler/src/Compiler/MonoDirect/Specialize.elm` | Add `requireTVar`, `isMonomorphicType`; tighten `specializeDefineNode`, `resolveType`, `specializePortNode` |
| `compiler/src/Compiler/MonoDirect/Monomorphize.elm` | Add `validateSolverCoverage` |
| `design_docs/invariants.csv` | Add SNAP_TVAR_001, SNAP_TVAR_002 |

---

## Resolved Questions

### Q1: How to obtain the annotation-level solver variable for function definitions?

**RESOLVED: Option D — expose the solver `Env` from `runWithIds`.**

The canonical, single HM variable for a function-as-a-value lives in the solver's `Env`. `CLocal`/`CForeign` constraints refer to names in `Env`, and `Type.toAnnotation` converts each entry to `Can.Annotation`. We extend `runWithIds` to also return the raw `Env` entries (as `annotationVars : Dict String Name.Name IO.Variable`) before annotation conversion.

This avoids changing constraint generation or shoehorning annotations into `NodeIds`. It's the Roc analogue of `PartialProc.annotation`/`body_var`.

Options A-C rejected because:
- **(A)** Recording annotation vars via NodeIds doesn't give a distinct HM var for the function as a whole — NodeIds only tracks expression/pattern IDs.
- **(B)** Reconstructing from body ID doesn't recover the full function type variable.
- **(C)** Synthesizing during LocalOpt creates variables outside the solver, violating the solver-backed principle.

### Q2: Are there polymorphic nodes that legitimately have no solver variable?

**RESOLVED: Yes, but they are never specialization roots.**

- `VarDebug` (`Can.VarDebug`): The typed constraint generator does not call `NodeIds.recordNodeVar` for debug intrinsics. These are never specialization roots — you specialize the function that *contains* them, not the debug intrinsic itself.
- Some `VarKernel` / accessor nodes may be polymorphic at the scheme level but are handled via `KernelAbi` logic, not HM-driven monomorphization.

For MonoDirect: `meta.tvar = Nothing` is acceptable on these leaf nodes as long as they are not used as specialization roots and `resolveType` never needs their local tvar for layout decisions. The enclosing function's annotation/body vars provide the solver context.

Implementation: Allow a small explicit whitelist in `resolveType` (VarDebug, some VarKernel), or rely on the `isMonomorphicType` check since in practice the enclosing specialization context will have already instantiated their types to concrete forms.

### Q3: Do recursive cycle definitions produce annotation-level solver variables?

**RESOLVED: Yes.**

`constrainRecursiveDefsWithIds` builds a constraint tree where each definition in the cycle is given a header (`name : tipe`) inside a `CLet` block, just like non-recursive defs. The HM solver's handling of `CLet` is uniform: it generalizes the function variables and extends `Env` with `name -> Variable` entries for each def in the group. That same `Env` is what `runWithIds` converts to `annotations`.

Once we expose `Env` from `runWithIds` (Step 1.1), cycle members get annotation vars exactly the same way as non-recursive defs.

### Q4: Is `SolverSnapshot.buildLocalView`'s internal use of TypeSubst acceptable?

**RESOLVED: Yes.**

`buildLocalView` uses `TypeSubst.canTypeToMonoType Dict.empty (typeOfVar var)`. This is:
- Downstream of the solver (operates on a fully-walked solver variable)
- A deterministic projection, not an independent inference engine
- Uses `Dict.empty` — no extra substitution context
- Cannot contradict the snapshot

The problematic TypeSubst usage was in MonoDirect.Specialize's fallback paths (`unify`, `unifyExtend`, `fillUnconstrainedCEcoWithErased`) that constructed substitutions *independently* of the solver. Those are being removed.

### Q5: Order of implementation vs. test breakage?

**RESOLVED: Tighten Specialize.elm (Phase 2) FIRST, then fix tvar coverage.**

Since this is a test-only pipeline, turning the fallback into a hard error gives immediate, precise feedback about every missing-tvar site. Each crash includes the node context and type, making it straightforward to trace back to the LocalOpt code path that needs fixing. This is more productive than trying to predict all missing-tvar sites upfront.

### Q6: Is `TOpt.tvarOf expr` always the correct tvar to copy into `wrapDestruct`?

**RESOLVED: Yes.**

In `wrapDestruct bodyType destructor expr`, the Destruct wrapper's type equals the inner expression's type (`bodyType`). The solver variable tracking that body type is `TOpt.tvarOf expr`. If the inner expression has `tvar = Nothing`, that's a missing-coverage bug that SNAP_TVAR_001 will expose via the stricter `resolveType`.

---

## Assumptions

1. **The solver's `Env` is exhaustive for all user-defined top-level names.** Every `Def`/`TypedDef` that goes through constraint solving gets an entry in `Env`.
2. **Recursive cycle members are in `Env`.** The `CLet` constraint for cycles extends `Env` with all cycle member names.
3. **Port implementations that are polymorphic will eventually be solver-backed.** The monomorphic fallback for ports is a temporary measure.
4. **VarCycle references are never specialization roots.** Only the definition nodes for cycle members are specialized.
5. **VarDebug and some VarKernel nodes are never specialization roots.** Their polymorphism is resolved by the enclosing function's solver context.
