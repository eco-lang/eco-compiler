# Plan: Solver-Root-Backed MVarId Assignment

## Problem

`AssignMVarIds` assigns `MVarId`s to type variables purely by **name** within per-node `SchemeEnv` scopes. This causes fragmentation: two expressions that the solver proved share the same type variable `a` can receive different `MVarId`s if they fall into different `SchemeEnv` scopes (e.g., annotation vs body, or across `withFreshBinding` boundaries). The monomorphizer then sees them as unrelated, leading to redundant specializations or incorrect unification.

## Goal

Derive `MVarId` identity from **solver union-find roots** (`IO.Variable`) instead of ad-hoc name scopes. Two `Can.TVar "a"` occurrences backed by the same solver root must always map to the same `MVarId`.

- **Identity**: solver root `IO.Variable` → `MVarId` via per-module `RootEnv`
- **Constraint**: still derived from `Name` at first allocation via `constraintFromName`

## Key Design Decisions (Resolved)

**Per-TVar roots come from `AllSchemeRoots`, not `Meta.tvar`.** `AllSchemeRoots` maps each definition's forall binders to their rooted solver variables. `Meta.tvar` is a single root per expression node — it serves as a "solver-backed" flag, not a way to decompose compound types like `a -> b -> Int`.

**`RootEnv` is `Dict Int MVarId` (simple).** Because `AssignMVarIds` operates per-module (see below), the `Int` key is just the root index from `IO.Pt idx`. No cross-module collision possible.

**`AllSchemeRoots` is accumulated via `ExprIdState` / `NodeIdState`.** The constraint generation state grows a `schemeBinderVars` field. No change to `constrainDefWithIds` return type.

**Let-bound polymorphic defs get scheme root entries** — they are `Can.TypedDef` in canonical AST, so the same `recordSchemeBinders` hook applies. `DefName` must encode enough to distinguish locals with the same source name (e.g., internal ID or path).

**`IO.Variable` indices are solver-run-local but stable within a module's `.elmo` snapshot.** Cross-module mixing is prevented by per-module `AssignMVarIds`. Cached `.elmo` files are self-consistent.

**MonoDirect has been removed.** Only the production monomorphizer path matters.

**Unannotated `Can.Def`s get binder roots from inferred annotations.** After solving, walk the descriptor structure from `annotationVars[defName]` to find rigid vars for each inferred `forall` binder, normalize to roots, and record in `AllSchemeRoots`.

**`AssignMVarIds` is refactored to operate per-module.** Group `GlobalGraph` nodes by module, run each module with its own fresh `GlobalMVarState` / `RootEnv`. Module identity is implicit in which `RootEnv` you're in.

## Current Data Flow

```
constrainWithIds → Solve.runWithIds → PostSolve → TCanBuild.fromCanonical → optimizeTyped → AssignMVarIds.assignIds → monomorphize
```

Key facts:
- `Solve.runWithIds` returns `solverState` (union-find arrays) but `typeCheckTyped` drops it
- `nodeVars` / `annotationVars` carry raw `IO.Variable`s (not necessarily roots)
- `Meta.tvar : Maybe IO.Variable` is preserved through TypedCanonical → TypedOptimized
- `AssignMVarIds` ignores `Meta.tvar` and rebuilds identity from `Can.TVar Name`

## Implementation Steps

### Phase 1: Normalize solver vars to roots after solving

**Step 1.1** — New module `Compiler/Type/SolverRoots.elm`

```elm
module Compiler.Type.SolverRoots exposing
    ( normalizeNodeVars
    , normalizeAnnotationVars
    , normalizeAllSchemeRoots
    , SchemeRootsForDef
    , AllSchemeRoots
    )
```

- `normalizeNodeVars : SolverSnapshot.SolverState -> Array (Maybe IO.Variable) -> Array (Maybe IO.Variable)` — maps each var to its UF root via `SolverSnapshot.resolveVariableHelp state.pointInfo`
- `normalizeAnnotationVars : SolverSnapshot.SolverState -> DMap.Dict String Name IO.Variable -> DMap.Dict String Name IO.Variable` — same for annotation vars
- `normalizeAllSchemeRoots : SolverSnapshot.SolverState -> AllSchemeRoots -> AllSchemeRoots` — normalize all binder vars to roots

Type aliases:
```elm
type alias SchemeRootsForDef = Dict Name.Name IO.Variable
type alias AllSchemeRoots = Dict DefName SchemeRootsForDef
```

These are trivial wrappers around the existing `resolveVariableHelp`.

**Step 1.2** — Ensure `resolveVariableHelp` is exposed from `SolverSnapshot`

File: `compiler/src/Compiler/Type/SolverSnapshot.elm`
Add a convenience that takes `SolverState`:
```elm
resolveVariable : SolverState -> IO.Variable -> IO.Variable
resolveVariable state var = resolveVariableHelp state.pointInfo var
```

**Step 1.3** — Forward `solverState` out of `typeCheckTyped`

File: `compiler/src/Compiler/Compile.elm`, function `typeCheckTyped`

Currently the `Ok` branch destructures `solverState` from `Solve.runWithIds` result but does not use or return it. Change to:
1. Call `SolverRoots.normalizeNodeVars solverState nodeVars` → `rootedNodeVars`
2. Call `SolverRoots.normalizeAnnotationVars solverState annotationVars` → `rootedAnnotationVars`
3. Pass `rootedNodeVars` to `TCanBuild.fromCanonical` (instead of raw `nodeVars`)
4. Return `rootedNodeVars` and `rootedAnnotationVars` in the result record
5. Return `solverState` — needed in Phase 2 for normalizing `AllSchemeRoots` and extracting inferred def binder roots

After this step, every `Meta.tvar` in TypedCanonical and TypedOptimized is guaranteed to be a UF root.

---

### Phase 2: Compute per-binder solver roots (AllSchemeRoots)

#### 2A: Annotated defs (Can.TypedDef)

**Step 2.1** — Extend `NodeIdState` with `schemeBinderVars`

File: likely `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm` or the `NodeIds` module

```elm
type alias NodeIdState =
    { ... existing fields ...
    , schemeBinderVars : Dict DefName SchemeRootsForDef
    }
```

Initialize `schemeBinderVars = Dict.empty`.

**Step 2.2** — Record binder→solver var in `constrainDefWithIds`

File: `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm`, lines ~95-129

In the `Can.TypedDef` branch, after computing `newRigids : Dict String IO.Variable` via `IO.traverseMapWithKey ... Type.nameToRigid newNames`:

```elm
-- newRigids already maps binderName -> fresh rigid solver var
-- Record into ExprIdState:
NodeIds.recordSchemeBinders defName newRigids
```

The `defName` must uniquely identify both top-level and local defs (use a fresh integer from `NodeIdState` or a path-based key).

Also handle `constrainDefWithIdsProg` (the top-level variant) — same logic applies.

**Step 2.3** — Handle let-bound `Can.TypedDef`s

Same hook applies — they go through the same `constrainDefWithIds` code path. The `DefName` must encode enough to distinguish multiple local defs with the same source name (e.g., `(enclosingDef, localIndex)` or a monotonic ID from `NodeIdState`).

#### 2B: Unannotated defs (Can.Def)

**Step 2.4** — Extract binder roots from inferred annotations post-solve

After `Solve.runWithIds` returns, for each unannotated `Can.Def` whose inferred annotation is `Can.Forall freeVars tipe`:

1. Look up `annotationVars[defName]` — the solver variable representing the full type
2. Walk the solver's descriptor structure from that variable to find the rigid vars corresponding to each `forall` binder in `freeVars`
3. Normalize those to union-find roots
4. Record as `AllSchemeRoots[defName] : SchemeRootsForDef`

This requires a helper function (in `SolverRoots` or `SolverSnapshot`):
```elm
extractBinderRootsFromInferred :
    SolverState
    -> Can.Annotation Name      -- inferred annotation
    -> IO.Variable               -- annotationVar for this def
    -> SchemeRootsForDef
```

The implementation walks the descriptor tree in lockstep with the annotation type, identifying which solver vars map to each `forall` binder name.

**Step 2.5** — Normalize and return `AllSchemeRoots` from `typeCheckTyped`

In `typeCheckTyped`, after solving:
1. Read `schemeBinderVars` from the final `ExprIdState` (annotated defs)
2. Compute binder roots for unannotated defs (Step 2.4)
3. Merge into a single `AllSchemeRoots`
4. Call `SolverRoots.normalizeAllSchemeRoots solverState allSchemeRoots` to root-normalize all entries
5. Return `allSchemeRoots` in the result record

---

### Phase 3: Thread AllSchemeRoots through TypedOptimized

**Step 3.1** — Extend `LocalGraphData`

File: `compiler/src/Compiler/AST/TypedOptimized.elm`

Add field:
```elm
type alias LocalGraphData id =
    { main : Maybe (Main id)
    , nodes : Data.Map.Dict (List String) Global (Node id)
    , fields : Dict Name Int
    , annotations : Annotations id
    , schemeRoots : AllSchemeRoots  -- NEW
    }
```

Update `localGraphEncoder` / `localGraphDecoder` to serialize/deserialize this field. The serialized representation is small: `Dict DefName (Dict Name (Pt Int))`.

**Step 3.2** — Extend `optimizeTyped` signature

File: `compiler/src/Compiler/LocalOpt/Typed/Module.elm`

```elm
optimizeTyped :
    Annotations
    -> ExprTypes
    -> ExprVars
    -> KernelTypes.KernelTypeEnv
    -> Data.Map.Dict String Name.Name IO.Variable
    -> SolverRoots.AllSchemeRoots               -- NEW
    -> TCan.Module
    -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
```

Populate `schemeRoots` in the `LocalGraph` it constructs.

**Step 3.3** — Update `typedOptimizeFromTyped` callsite

File: `compiler/src/Compiler/Compile.elm`

Pass `allSchemeRoots` through to `optimizeTyped`.

---

### Phase 4: Refactor AssignMVarIds to per-module, root-backed

**Step 4.1** — Refactor `assignIds` to operate per-module

File: `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm`

Change the driver from:
```elm
assignIds : TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph TypeIds.MVarId, GlobalMVarState )
```

To:
1. Group nodes by module (`TOpt.Global`'s `home` field)
2. For each module independently:
   - Initialize fresh `GlobalMVarState` with `nextId`, empty `constraints`, empty `rootEnv`
   - Extract that module's `AllSchemeRoots` from the `GlobalGraph`'s `LocalGraphData`
   - Run `rewriteModuleNodes` over that module's nodes + annotations
   - Collect rewritten nodes + final state
3. Merge all per-module results into the final `GlobalGraph MVarId`

The `MVarId` counter can either be global (shared across modules for uniqueness) or per-module (with a module-local offset). Global counter is simpler and already matches the existing design.

**Step 4.2** — Change `RootEnv` and `Ctx`

```elm
type alias GlobalMVarState =
    { nextId : TypeIds.MVarId
    , constraints : Dict Int Mono.Constraint
    , rootEnv : Dict Int TypeIds.MVarId  -- rootIndex → MVarId, per-module
    }

type alias Ctx =
    { env : SchemeEnv                          -- name-based fallback (secondary)
    , state : GlobalMVarState
    , schemeRootsForDef : SchemeRootsForDef    -- current def's binder→root mapping
    }
```

No `currentModule` field needed — module identity is implicit because we process one module at a time.

**Step 4.3** — Add `ensureMVarIdForRoot`

```elm
ensureMVarIdForRoot : IO.Variable -> Name -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureMVarIdForRoot root name ctx =
    let
        rootIdx = case root of IO.Pt idx -> idx
    in
    case Dict.get rootIdx ctx.state.rootEnv of
        Just mvarId ->
            ( mvarId, ctx )

        Nothing ->
            let
                ( mvarId, newState ) = freshMVarId (constraintFromName name) ctx.state
                rootEnv1 = Dict.insert rootIdx mvarId newState.rootEnv
            in
            ( mvarId, { ctx | state = { newState | rootEnv = rootEnv1 } } )
```

**Step 4.4** — Rework `rewriteNodes` / `rewriteNode` to use `AllSchemeRoots`

For each node in the module:
1. Extract the def name from `TOpt.Global`
2. Look up `schemeRootsForDef = AllSchemeRoots[defName] |> Maybe.withDefault Dict.empty`
3. Build `Ctx` with this `schemeRootsForDef`
4. Process the node

**Step 4.5** — Rework `rewriteMeta` to build `SchemeEnv` from roots

```elm
rewriteMeta : Ctx -> TOpt.Meta Name -> ( TOpt.Meta TypeIds.MVarId, Ctx )
rewriteMeta ctx meta =
    let
        ( newType, ctx1 ) = rewriteCanTypeRooted ctx meta.tipe
    in
    ( { tipe = newType, tvar = meta.tvar }, ctx1 )
```

**Step 4.6** — Implement `rewriteCanTypeRooted`

Replaces `rewriteCanType` for solver-backed types. For each `Can.TVar name`:

```elm
rewriteCanTypeRooted : Ctx -> Can.Type Name -> ( Can.Type TypeIds.MVarId, Ctx )
rewriteCanTypeRooted ctx canType =
    case canType of
        Can.TVar name ->
            case Dict.get name ctx.schemeRootsForDef of
                Just root ->
                    -- Root-backed: use ensureMVarIdForRoot
                    let ( mvarId, ctx1 ) = ensureMVarIdForRoot root name ctx
                    in ( Can.TVar mvarId, ctx1 )

                Nothing ->
                    -- No root (synthetic or untracked): name-based fallback
                    let ( mvarId, ctx1 ) = ensureMVarId name ctx
                    in ( Can.TVar mvarId, ctx1 )

        Can.TLambda from to ->
            ...recurse...

        Can.TType home typeName args ->
            ...recurse...

        -- TTRecord, TTuple, TAlias: recurse similarly
```

The key insight: `ctx.schemeRootsForDef` provides per-binder roots for all `Can.TVar` names within the current def's scope. Two different TVars (`a`, `b`) each get their own root from this dict. The same root always maps to the same `MVarId` via `RootEnv`.

**Step 4.7** — Rework `rewriteAnnotations` to use `AllSchemeRoots`

```elm
rewriteAnnotations :
    AllSchemeRoots
    -> Dict Name (Can.Annotation Name)
    -> GlobalMVarState
    -> ( Dict Name (Can.Annotation TypeIds.MVarId), GlobalMVarState )
```

For each annotation `Can.Forall freeVars tipe`:
1. Look up `schemeRootsForDef = AllSchemeRoots[defName]`
2. Build `Ctx` with that `schemeRootsForDef`
3. Rewrite `tipe` using `rewriteCanTypeRooted`
4. Binders with roots → `ensureMVarIdForRoot`, binders without → `ensureMVarId`

**Step 4.8** — Update `Monomorphize.monomorphize` callsite

File: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Extract `AllSchemeRoots` from the `GlobalGraph`'s per-module `LocalGraphData.schemeRoots`. Pass to the per-module `AssignMVarIds` driver.

---

### Phase 5: Ports fallback

For `PortIncoming` / `PortOutgoing` nodes, `schemeRootsForDef` will typically be empty (ports don't have forall binders in the usual sense). The fallback in `rewriteCanTypeRooted` (`Dict.get name ctx.schemeRootsForDef` → `Nothing` → `ensureMVarId name`) handles this automatically. Port type variables remain name-based.

---

### Phase 6: Testing

**Step 6.1** — Root consistency invariant test

For each module processed by `AssignMVarIds`:
- For every `(binderName, rootVar)` pair in `AllSchemeRoots[defName]`:
  - `rootVar` must map to exactly one `MVarId` in `RootEnv`
  - That `MVarId`'s constraint must equal `constraintFromName binderName`
- For every `Can.TVar` in a node's type that has a root in `schemeRootsForDef`:
  - The assigned `MVarId` must match `RootEnv[rootIdx]`

**Step 6.2** — No-fragmentation smoke test

Small Elm programs where a single type variable flows through:
```elm
id : a -> a
id x = x
```
Assert:
- The `a` in the annotation and the `a` in the body expression type both get the same `MVarId`
- The `SchemeEnv` and `RootEnv` agree

**Step 6.3** — Multi-binder test

```elm
pair : a -> b -> (a, b)
pair x y = (x, y)
```
Assert `a` and `b` get distinct `MVarId`s, each consistent across annotation and body.

**Step 6.4** — Regression: run existing POST_*, TOPT_*, and monomorphization test suites

No `Can.Type` structures change, so these should pass. Run:
```bash
cmake --build build --target full
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

---

## Assumptions

1. `Solve.runWithIds` already returns `solverState` and `typeCheckTyped` has access to it (confirmed).
2. `SolverSnapshot.resolveVariableHelp` correctly finds UF roots (confirmed).
3. Normalizing vars to roots is idempotent and cheap (just following `Link` chains).
4. `Meta.tvar` is faithfully propagated through TypedCanonical → TypedOptimized without mutation (confirmed).
5. Phantom type variables that appear only in annotations (never in expression types) will need `AllSchemeRoots` to get root-backed `MVarId`s.
6. The existing `constraintFromName` classification is correct and preserved as-is.
7. `IO.Variable` indices are solver-run-local but stable within a module's `.elmo` snapshot — cross-module mixing prevented by per-module processing.
8. MonoDirect has been removed; only the production monomorphizer path exists.

## Files Changed (by phase)

| Phase | File | Change |
|-------|------|--------|
| 1.1 | `compiler/src/Compiler/Type/SolverRoots.elm` | **NEW** — `normalizeNodeVars`, `normalizeAnnotationVars`, `normalizeAllSchemeRoots`, type aliases |
| 1.2 | `compiler/src/Compiler/Type/SolverSnapshot.elm` | Expose `resolveVariable` convenience |
| 1.3 | `compiler/src/Compiler/Compile.elm` | Normalize vars in `typeCheckTyped`, forward `solverState` |
| 2.1 | `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm` (or NodeIds module) | Extend `NodeIdState` with `schemeBinderVars`, add `recordSchemeBinders` |
| 2.2 | `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm` | Record `newRigids` in `constrainDefWithIds` / `constrainDefWithIdsProg` for `Can.TypedDef` |
| 2.4 | `compiler/src/Compiler/Type/SolverRoots.elm` | Add `extractBinderRootsFromInferred` for unannotated defs |
| 2.5 | `compiler/src/Compiler/Compile.elm` | Compute + return `allSchemeRoots` (annotated + inferred) |
| 3.1 | `compiler/src/Compiler/AST/TypedOptimized.elm` | Extend `LocalGraphData` with `schemeRoots`, update encoder/decoder |
| 3.2 | `compiler/src/Compiler/LocalOpt/Typed/Module.elm` | Extend `optimizeTyped` signature to accept `AllSchemeRoots` |
| 3.3 | `compiler/src/Compiler/Compile.elm` | Pass `allSchemeRoots` to `optimizeTyped` |
| 4.1 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Refactor `assignIds` to per-module processing |
| 4.2 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Extend `GlobalMVarState` with `rootEnv`, extend `Ctx` with `schemeRootsForDef` |
| 4.3 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Add `ensureMVarIdForRoot` |
| 4.4 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Rework `rewriteNodes` to look up `AllSchemeRoots` per def |
| 4.5-4.6 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Rework `rewriteMeta` + new `rewriteCanTypeRooted` |
| 4.7 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Rework `rewriteAnnotations` with root-backed binders |
| 4.8 | `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | Extract `AllSchemeRoots` from `GlobalGraph`, pass to per-module `assignIds` |
| 5 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Port fallback (handled by `rewriteCanTypeRooted` `Nothing` branch) |
| 6 | Test files TBD | Invariant + smoke + regression tests |

## Remaining Open Items

These are not design blockers but need resolution during implementation:

1. **DefName representation**: What type to use for `DefName` in `AllSchemeRoots` to uniquely identify both top-level and let-bound defs? Options: `Name.Name` (sufficient if names are already unique within a module), monotonic `Int` from `NodeIdState`, or a path-based composite.

2. **`extractBinderRootsFromInferred` implementation complexity**: Walking the solver descriptor tree in lockstep with an inferred annotation type to match binders to vars is non-trivial. May need to prototype this step first to assess feasibility vs. alternative approaches (e.g., instrumenting the solver's generalization step to record the mapping directly).

3. **`GlobalMVarState.nextId` sharing across modules**: If the per-module refactoring uses a shared counter for `MVarId` uniqueness, the fold order over modules must be deterministic. Alternatively, use per-module ID ranges with offsets.

4. **`withFreshBinding` interaction**: Under the new design, `withFreshBinding` still creates a fresh `SchemeEnv` for let-bound defs. But if that let-bound def has its own entry in `AllSchemeRoots`, the `schemeRootsForDef` in `Ctx` should switch to that entry when entering the let body. Need to wire this correctly in `rewriteNode` / `rewriteExpr`.
