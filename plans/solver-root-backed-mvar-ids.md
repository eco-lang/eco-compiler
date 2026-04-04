# Plan: Solver-Root-Backed MVarId Assignment

## Problem

`AssignMVarIds` assigns `MVarId`s to type variables purely by **name** within per-node `SchemeEnv` scopes. This causes fragmentation: two expressions that the solver proved share the same type variable `a` can receive different `MVarId`s if they fall into different `SchemeEnv` scopes (e.g., annotation vs body, or across `withFreshBinding` boundaries). The monomorphizer then sees them as unrelated, leading to redundant specializations or incorrect unification.

## Goal

Derive `MVarId` identity from **solver union-find roots** (`IO.Variable`) instead of ad-hoc name scopes. Two `Can.TVar "a"` occurrences backed by the same solver root must always map to the same `MVarId`.

Identity comes from the solver root; constraint classification (`CNumber`, `CComparable`, `CEcoValue`) still comes from the `Name` prefix via `constraintFromName`.

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
    )
```

- `normalizeNodeVars : SolverSnapshot.SolverState -> Array (Maybe IO.Variable) -> Array (Maybe IO.Variable)` — maps each var to its UF root via `SolverSnapshot.resolveVariableHelp state.pointInfo`
- `normalizeAnnotationVars : SolverSnapshot.SolverState -> DMap.Dict String Name IO.Variable -> DMap.Dict String Name IO.Variable` — same for annotation vars

These are trivial wrappers around the existing `resolveVariableHelp`.

**Step 1.2** — Ensure `resolveVariableHelp` is exposed from `SolverSnapshot`

File: `compiler/src/Compiler/Type/SolverSnapshot.elm`
Currently takes `Array IO.PointInfo`. Add a convenience that takes `SolverState`:
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
5. Optionally return `solverState` if needed downstream (see Phase 2 questions)

After this step, every `Meta.tvar` in TypedCanonical and TypedOptimized is guaranteed to be a UF root.

---

### Phase 2: Compute per-binder solver roots (AllSchemeRoots)

This is the hardest part. We need a mapping: for each top-level def, which solver variable corresponds to each `forall` binder name.

**Step 2.1** — Instrument constraint generation to record binder→solver var

File: `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm`, lines ~95-129

In `constrainDefWithIds`, when processing `Can.TypedDef`:
- Currently calls `Type.nameToRigid` for each free var, producing fresh rigid solver variables
- These vars are placed into `newRtv` and used for the body, then discarded
- **Change**: accumulate a side table `Dict Name IO.Variable` mapping binder name → rigid solver var
- Thread this side table out alongside the constraint and node var state

Type aliases:
```elm
type alias SchemeRootsForDef = Dict Name.Name IO.Variable
type alias AllSchemeRoots = Dict Name.Name SchemeRootsForDef  -- defName → (binderName → rootVar)
```

**Step 2.2** — Thread binder var table through constraint generation

The constraint generation pipeline is:
```
constrainWithIds (Module level) → constrainDefWithIds (per def) → IO (Constraint, State)
```

Add `AllSchemeRoots` accumulation to the state threaded through `constrainWithIds` at the module level. Each `constrainDefWithIds` call adds its `(defName, SchemeRootsForDef)` entry.

**Step 2.3** — Normalize binder vars to roots

After `Solve.runWithIds` returns, normalize every var in `AllSchemeRoots` using `SolverRoots.resolveVariable`. The rigid vars created in constraint generation go through the solver's union-find, so their roots may differ from the original point indices.

**Step 2.4** — Return `AllSchemeRoots` from `typeCheckTyped`

Add `allSchemeRoots : AllSchemeRoots` to the result record of `typeCheckTyped`.

---

### Phase 3: Thread AllSchemeRoots through TypedOptimized

**Step 3.1** — Extend `LocalGraphData`

File: `compiler/src/Compiler/AST/TypedOptimized.elm`

Add field:
```elm
type alias LocalGraphData id =
    { main : ...
    , nodes : ...
    , fields : ...
    , annotations : ...
    , schemeRoots : AllSchemeRoots  -- NEW
    }
```

Update `localGraphEncoder` / `localGraphDecoder` to serialize/deserialize this field.

**Step 3.2** — Extend `optimizeTyped` signature

File: `compiler/src/Compiler/LocalOpt/Typed/Module.elm`

Add `AllSchemeRoots` parameter; populate `schemeRoots` in the `LocalGraph` it constructs.

**Step 3.3** — Update `typedOptimizeFromTyped` callsite

File: `compiler/src/Compiler/Compile.elm`

Pass `allSchemeRoots` through to `optimizeTyped`.

---

### Phase 4: Rework AssignMVarIds to use solver roots

**Step 4.1** — Extend `GlobalMVarState` with `RootEnv`

File: `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm`

```elm
type alias GlobalMVarState =
    { nextId : TypeIds.MVarId
    , constraints : Dict Int Mono.Constraint
    , rootEnv : Dict Int TypeIds.MVarId  -- encoded (moduleCanonical, rootVar) → MVarId
    }
```

**Step 4.2** — Extend `Ctx` with `currentModule`

```elm
type alias Ctx =
    { env : SchemeEnv
    , state : GlobalMVarState
    , currentModule : IO.Canonical
    }
```

In `rewriteNodes`, extract the module from each `TOpt.Global home _` and populate `ctx.currentModule`.

**Step 4.3** — Add `ensureMVarIdForRoot`

```elm
ensureMVarIdForRoot : IO.Variable -> Name -> Ctx -> ( TypeIds.MVarId, Ctx )
```

- Key: encode `(ctx.currentModule, rootVar)` into an `Int` for `rootEnv` lookup
- If found: return cached `MVarId`
- If not: allocate fresh via `freshMVarId (constraintFromName name)`, insert into `rootEnv`

**Step 4.4** — Change `rewriteMeta` to use roots

Currently:
```elm
rewriteMeta ctx meta =
    let ( newType, ctx1 ) = rewriteCanType ctx meta.tipe
    in ( { tipe = newType, tvar = meta.tvar }, ctx1 )
```

Change to dispatch on `meta.tvar`:
- `Just rootVar` → use `rewriteCanTypeWithRoot` which calls `ensureMVarIdForRoot` for each `Can.TVar`
- `Nothing` → fall back to existing `rewriteCanType` (name-based, for synthetic nodes)

**Step 4.5** — Implement `rewriteCanTypeWithRoot`

New function that walks `Can.Type Name` like `rewriteCanType`, but for `Can.TVar name`:
- Calls `ensureMVarIdForRoot rootVar name ctx` instead of `ensureMVarId name ctx`
- The `rootVar` comes from `meta.tvar` (the expression's root)

**Issue**: `meta.tvar` is a single root for the whole expression, but the expression's type may contain multiple `Can.TVar` names (e.g., `a -> b`). A single root var does NOT give us roots for `a` and `b` individually. See **Open Question 1**.

**Step 4.6** — Wire `AllSchemeRoots` into annotation rewriting

Change `assignIds` to accept `AllSchemeRoots`. In `rewriteAnnotations`, for each def:
1. Look up `SchemeRootsForDef` from `AllSchemeRoots`
2. For each `freeVars` binder with a known root, use `ensureMVarIdForRoot`
3. For binders without roots (phantom vars without solver backing), fall back to `ensureMVarId`

**Step 4.7** — Update `Monomorphize.monomorphize` callsite

Pass `AllSchemeRoots` (extracted from the `GlobalGraph`'s `LocalGraphData.schemeRoots`) to `AssignMVarIds.assignIds`.

---

### Phase 5: Ports fallback

For `PortIncoming` / `PortOutgoing` nodes, `meta.tvar` may be `Nothing` or unreliable. Keep the existing name-based `ensureMVarId` path for these. The dispatch in Step 4.4 already handles this: `Nothing` → name-based fallback.

---

### Phase 6: Testing

**Step 6.1** — Root consistency invariant test

For every `TOpt.Expr` with `Meta.tvar = Just root`, verify that the `MVarId` assigned to each `Can.TVar` in its type matches `rootEnv[(module, root)]`.

**Step 6.2** — No-fragmentation smoke test

Small Elm programs where a single type variable flows across definitions:
```elm
id : a -> a
id x = x

use : a -> a
use y = id y
```
Assert that the `a` in both gets the same `MVarId` (within the same module).

**Step 6.3** — Regression: run existing POST_*, TOPT_*, and monomorphization test suites

No `Can.Type` structures change, so these should pass.

---

## Open Questions

### Q1 (Critical): How to get per-TVar roots inside a compound type?

`Meta.tvar` gives ONE root for the entire expression. But an expression typed `a -> b -> Int` has two distinct type variables. `rewriteCanTypeWithRoot` needs a root for each `Can.TVar` name in the type, not just one for the whole expression.

**Options**:
- **(a)** Use `AllSchemeRoots` for ALL TVar resolution, not just annotations. At the node level, look up the def's `SchemeRootsForDef` and use it inside `rewriteCanTypeWithRoot`. `Meta.tvar` would serve only as a "this node is solver-backed" flag.
- **(b)** Extend `Meta` to carry `Dict Name IO.Variable` (per-TVar roots) instead of a single `Maybe IO.Variable`. This is more precise but requires plumbing through the entire AST.
- **(c)** Walk the solver's descriptor graph from `meta.tvar` to decompose a compound type's root into sub-roots for each TVar position. This requires access to `solverState` at rewrite time and complex structural matching.

**Recommendation**: Option (a) — use `AllSchemeRoots` as the primary source. It already maps binder names to roots per-def. Inside `rewriteNodes`, look up the current node's def name in `AllSchemeRoots` and use that mapping for all `Can.TVar` resolution. Fall back to name-based only if the def has no entry.

### Q2: How to encode the `(IO.Canonical, IO.Variable)` key for `rootEnv`?

`IO.Canonical` is a module path (package + module name). `IO.Variable` is `Pt Int`. Options:
- Hash `IO.Canonical` to an `Int` and combine with the `Pt Int` index (risk of collision)
- Use a nested dict: `Dict ComparableCanonical (Dict Int MVarId)`
- Use a string key: `"pkg/Mod.Name:" ++ String.fromInt idx`

**Recommendation**: Nested dict is cleanest and collision-free.

### Q3: Where exactly in `constrainDefWithIds` do we capture binder vars?

The rigid vars are created via `IO.traverseMapWithKey ... Type.nameToRigid newNames`. This returns `newRigids : Dict Name IO.Variable`. We need to:
1. Thread this dict out alongside the constraint
2. Associate it with the def name

The constraint generation return type currently is `IO (Constraint, ConstrainState)` (or similar). We need to confirm the exact threading mechanism and whether `ConstrainState` can carry `AllSchemeRoots` or if we need a separate accumulator.

### Q4: Do `withFreshBinding` scopes in AssignMVarIds still make sense?

Currently `withFreshBinding` creates a fresh empty `SchemeEnv` for nested let-bindings. With root-backed assignment:
- If we use Option (a) from Q1, `SchemeEnv` becomes secondary — roots from `AllSchemeRoots` take priority
- `withFreshBinding` would still be needed for let-bound definitions that introduce their own type variables (not in the top-level scheme)

Need to verify: do let-bound definitions in TypedOptimized ever have their own `SchemeRootsForDef` entries, or only top-level defs?

### Q5: Serialization cost of `AllSchemeRoots`

`AllSchemeRoots` will be serialized into every `.elmo` artifact via `localGraphEncoder`. Each entry is `(defName, Dict binderName (Pt Int))`. For most modules this is small (a few defs, each with 0-3 type parameters). But:
- Is `IO.Variable` (`Pt Int`) stable across incremental compilation? If the solver assigns different point indices on recompilation, cached `.elmo` files would be stale.
- **If not stable**: we may need to store roots differently (e.g., as opaque per-module indices assigned post-solve) or recompute `AllSchemeRoots` at link time rather than caching it.

### Q6: Interaction with MonoDirect solver-driven monomorphization

The design targets the standard `AssignMVarIds` → `Monomorphize` path. Does the MonoDirect path (`Compiler.Monomorphize.MonoDirect`) also suffer from the same fragmentation? If so, does it need analogous changes, or does it already use solver snapshots directly?

### Q7: Non-TypedDef definitions (Can.Def without annotation)

`constrainDefWithIds` handles both `Can.TypedDef` (with annotation and `freeVars`) and `Can.Def` (no annotation). For `Can.Def`, there are no explicit `forall` binders — the scheme is inferred. How do we compute `SchemeRootsForDef` for these? Options:
- Skip them (they have no rigid vars, so `AllSchemeRoots` has no entry → fall back to name-based)
- Extract binder→var mapping from the inferred `Can.Annotation` + `annotationVars` post-solve

### Q8: What happens for imported/cross-module type variables?

When module A imports a function from module B, the type variables in B's annotation are re-instantiated in A's solver. The roots will be different per-module. Is this handled correctly by keying `rootEnv` on `(IO.Canonical, rootVar)`? Specifically: do imported definitions' nodes appear in the `GlobalGraph` with their original module's `IO.Canonical`?

## Assumptions

1. `Solve.runWithIds` already returns `solverState` and `typeCheckTyped` has access to it (confirmed by exploration).
2. `SolverSnapshot.resolveVariableHelp` correctly finds UF roots (confirmed).
3. Normalizing vars to roots is idempotent and cheap (just following `Link` chains).
4. `Meta.tvar` is faithfully propagated through TypedCanonical → TypedOptimized without mutation (confirmed).
5. Phantom type variables that appear only in annotations (never in expression types) will need `AllSchemeRoots` to get root-backed `MVarId`s — `Meta.tvar` alone is insufficient for these.
6. The existing `constraintFromName` classification is correct and should be preserved as-is.

## Files Changed (by phase)

| Phase | File | Change |
|-------|------|--------|
| 1.1 | `compiler/src/Compiler/Type/SolverRoots.elm` | **NEW** — `normalizeNodeVars`, `normalizeAnnotationVars` |
| 1.2 | `compiler/src/Compiler/Type/SolverSnapshot.elm` | Expose `resolveVariable` convenience |
| 1.3 | `compiler/src/Compiler/Compile.elm` | Normalize vars in `typeCheckTyped`, return rooted vars |
| 2.1 | `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm` | Record binder→var in `constrainDefWithIds` |
| 2.2 | `compiler/src/Compiler/Type/Constrain/Typed/Module.elm` (or similar) | Thread `AllSchemeRoots` accumulator |
| 2.3 | `compiler/src/Compiler/Type/SolverRoots.elm` | Add `normalizeAllSchemeRoots` |
| 2.4 | `compiler/src/Compiler/Compile.elm` | Compute + return `allSchemeRoots` |
| 3.1 | `compiler/src/Compiler/AST/TypedOptimized.elm` | Extend `LocalGraphData`, update encoder/decoder |
| 3.2 | `compiler/src/Compiler/LocalOpt/Typed/Module.elm` | Extend `optimizeTyped` signature |
| 3.3 | `compiler/src/Compiler/Compile.elm` | Pass `allSchemeRoots` to `optimizeTyped` |
| 4.1-4.7 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Core rework: `RootEnv`, `currentModule`, root-backed rewriting |
| 4.7 | `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | Pass `AllSchemeRoots` to `assignIds` |
| 5 | `compiler/src/Compiler/Monomorphize/AssignMVarIds.elm` | Port fallback (covered by Step 4.4 dispatch) |
| 6 | Test files TBD | Invariant + smoke tests |
