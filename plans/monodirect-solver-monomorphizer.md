# MonoDirect: Solver-Variable-Aware Monomorphizer

## Goal

Add solver variables to TypedCanonical and TypedOptimized IRs, retain the HM solver state for local queries, introduce a new `Compiler.MonoDirect.*` monomorphizer that uses solver-driven type resolution instead of `TypeSubst`, and wire it only into a test-only pipeline.

## Key Design Decisions

- **Additive only**: Existing IRs gain new metadata (`tvar`/`Meta`) but no existing field changes
- **Production untouched**: MonoDirect runs only in test pipeline; existing monomorphizer unchanged
- **Solver snapshot**: Capture union-find state inside the IO monad *before* `unsafePerformIO` discards it
- **Fallback strategy**: Where `tvar = Nothing`, MonoDirect falls back to existing `TypeSubst` on `Can.Type`

## Questions / Risks

1. **IO state snapshot**: The `IO` monad (`State -> (State, a)`) discards state via `unsafePerformIO`. The snapshot must be built *inside* the IO chain in `runWithIds` before return. Since `State.ioRefsDescriptor` and `State.ioRefsPointInfo` are plain `Array` values (immutable in Elm), snapshotting is just capturing references — no deep copy needed.

2. **TypedOptimized surgery**: Every `TOpt.Expr` variant has a trailing `Can.Type`. Changing to `Meta` is a large mechanical refactor (~25 variants). The `typeOf` helper, all pattern matches in `LocalOpt.Typed.Expression.elm`, `LocalOpt.Typed.Module.elm`, and downstream consumers (`Monomorphize.Specialize`, etc.) must update. This is the highest-risk change.

3. **Local unification soundness**: `withLocalUnification` must create a *copy* of the solver state (or an overlay) to avoid corrupting the shared snapshot. Since `IO.State` contains plain `Array` values (structurally shared in Elm), we can just thread a copy through local IO operations.

4. **Scope of `nodeVars`**: `NodeVarMap = Array (Maybe IO.Variable)` maps ExprId → Variable. After optimization, TypedOptimized nodes no longer carry ExprIds directly — the `tvar` field on `TCan.TypedExpr` bridges this gap by being propagated through optimization.

5. **`SolverCore` opacity**: The plan exposes `SolverCore` as opaque from `Solve.elm`. An alternative is to define it in `SolverSnapshot.elm` directly (importing IO types). We recommend defining it in `SolverSnapshot.elm` to avoid expanding `Solve.elm`'s public API.

---

## Phase 1: Extend Solver Output

### 1.1 Modify `Compiler.Type.Solve.runWithIds`

**File**: `compiler/src/Compiler/Type/Solve.elm` (lines 100–127)

Current return type:
```elm
IO (Result (NE.Nonempty Error.Error) { annotations : Data.Map.Dict String Name.Name Can.Annotation, nodeTypes : Array (Maybe Can.Type) })
```

New return type — add `nodeVars` and `solverState` to the success record:
```elm
IO (Result (NE.Nonempty Error.Error)
    { annotations : Data.Map.Dict String Name.Name Can.Annotation
    , nodeTypes : Array (Maybe Can.Type)
    , nodeVars : Array (Maybe Variable)
    , solverState : SolverState
    })
```

Where `SolverState` is a snapshot of the IO state arrays:
```elm
type alias SolverState =
    { descriptors : Array Descriptor
    , pointInfo : Array PointInfo
    , weights : Array Int
    }
```

**Implementation**: Inside `runWithIds`, after `toCanTypeBatch nodeVars` succeeds, snapshot the current IO state:

```elm
-- After computing nodeTypes, snapshot the state
IO.andThen
    (\nodeTypes ->
        -- Snapshot: just read the current state arrays
        \s ->
            ( s
            , Ok
                { annotations = annotations
                , nodeTypes = nodeTypes
                , nodeVars = nodeVars
                , solverState =
                    { descriptors = s.ioRefsDescriptor
                    , pointInfo = s.ioRefsPointInfo
                    , weights = s.ioRefsWeight
                    }
                }
            )
    )
    (Type.toCanTypeBatch nodeVars)
```

**Backwards compatibility**: Existing call sites destructure `{ annotations, nodeTypes }` — Elm record patterns allow extra fields, so no breakage.

**Files to update** (callers of `runWithIds` that destructure the Ok record):
- `compiler/src/Compiler/Compile.elm` — `typeCheckTyped` (line ~263): add `nodeVars` and `solverState` to pattern
- `compiler/tests/TestLogic/TestPipeline.elm` — `runWithIdsTypeCheck` (line ~378): add new fields to pattern

### 1.2 Export new types from `System.TypeCheck.IO`

`PointInfo` and `Descriptor` are already exported. `SolverState` will be defined in `Solve.elm` or `SolverSnapshot.elm` using these types.

Verify that `IO.elm` exports `PointInfo(..)` — it does (line 8).

---

## Phase 2: SolverSnapshot Module

### 2.1 Create `compiler/src/Compiler/Type/SolverSnapshot.elm`

**New file**. Public API:

```elm
module Compiler.Type.SolverSnapshot exposing
    ( SolverSnapshot
    , SolverState
    , TypeVar
    , fromSolveResult
    , exprVarFromId
    , lookupDescriptor
    , resolveVariable
    , withLocalUnification
    , LocalView
    )
```

**Types**:

```elm
type alias TypeVar = IO.Variable  -- = IO.Point = Pt Int

type alias SolverState =
    { descriptors : Array IO.Descriptor
    , pointInfo : Array IO.PointInfo
    , weights : Array Int
    }

type alias SolverSnapshot =
    { state : SolverState
    , nodeVars : Array (Maybe TypeVar)
    }
```

**Core functions**:

```elm
fromSolveResult : { a | nodeVars : Array (Maybe TypeVar), solverState : SolverState } -> SolverSnapshot

exprVarFromId : SolverSnapshot -> Int -> Maybe TypeVar
-- Array.get id snap.nodeVars |> Maybe.andThen identity

resolveVariable : SolverSnapshot -> TypeVar -> TypeVar
-- Follow union-find parent links in snap.state.pointInfo to find root

lookupDescriptor : SolverSnapshot -> TypeVar -> IO.Descriptor
-- resolveVariable then index into snap.state.descriptors
```

**Local unification**:

```elm
type alias LocalView =
    { typeOf : TypeVar -> Can.Type
    , monoTypeOf : TypeVar -> Mono.MonoType
    }

withLocalUnification :
    SolverSnapshot
    -> List TypeVar                  -- roots to relax (rigid → flex)
    -> List ( TypeVar, TypeVar )     -- equalities to enforce
    -> (LocalView -> a)
    -> a
```

Implementation:
1. Copy `SolverState` arrays (they're immutable Elm arrays so this is O(1) structural sharing)
2. For each root var: if its descriptor has `RigidVar` or `RigidSuper`, replace with `FlexVar`/`FlexSuper`
3. Run the solver's `unify` on each `(v1, v2)` pair using the local state via IO monad
4. Build `LocalView`:
   - `typeOf v` = use `Type.variableToCanType` on the local state
   - `monoTypeOf v` = `TypeSubst.canTypeToMonoType (typeOf v)` (or `applySubst Dict.empty (typeOf v)`)
5. Call the callback with the `LocalView`, discard local state

**Note**: Running `unify` locally requires calling into `Compiler.Type.Unify` within an IO context. Since the IO monad is just `State -> (State, a)`, we can construct a local `IO.State` from the copied arrays, run `unify`, and extract results. This mirrors how `unsafePerformIO` works but with a pre-populated state.

---

## Phase 3: Extend TypedCanonical

### 3.1 Add `tvar` to `TypedExpr`

**File**: `compiler/src/Compiler/AST/TypedCanonical.elm`

Current:
```elm
type Expr_
    = TypedExpr { expr : Can.Expr_, tipe : Can.Type }
```

Change to:
```elm
type Expr_
    = TypedExpr { expr : Can.Expr_, tipe : Can.Type, tvar : Maybe IO.Variable }
```

Add import: `import System.TypeCheck.IO as IO`

### 3.2 Add `ExprVars` type alias

**File**: `compiler/src/Compiler/AST/TypedCanonical.elm`

Currently has:
```elm
type alias ExprTypes = Array (Maybe Can.Type)
type alias NodeTypes = Array (Maybe Can.Type)
```

Add:
```elm
type alias ExprVars = Array (Maybe IO.Variable)
```

### 3.3 Update `TypedCanonical.Build.fromCanonical`

**File**: `compiler/src/Compiler/TypedCanonical/Build.elm`

Current signature:
```elm
fromCanonical : Can.Module -> ExprTypes -> Module
```

New signature:
```elm
fromCanonical : Can.Module -> ExprTypes -> ExprVars -> Module
```

Thread `ExprVars` through all helpers:
- `toTypedDecls exprTypes exprVars ...`
- `toTypedDef exprTypes exprVars ...`
- `toTypedExpr exprTypes exprVars ...`

In `toTypedExpr`, look up both:
```elm
toTypedExpr exprTypes exprVars (A.At region info) =
    let
        tipe = Array.get info.id exprTypes |> Maybe.andThen identity |> ...
        tvar = Array.get info.id exprVars |> Maybe.andThen identity
    in
    A.At region (TCan.TypedExpr { expr = info.node, tipe = tipe, tvar = tvar })
```

### 3.4 Update callers of `fromCanonical`

- `compiler/src/Compiler/Compile.elm` line ~275: `TCanBuild.fromCanonical canonical fixedNodeTypes` → add `nodeVars` argument
- `compiler/tests/TestLogic/TestPipeline.elm` line ~253: `TCanBuild.fromCanonical canonical nodeTypesPost` → add `nodeVars` argument

---

## Phase 4: Extend TypedOptimized

### 4.1 Add `Meta` type to `Compiler.AST.TypedOptimized`

**File**: `compiler/src/Compiler/AST/TypedOptimized.elm`

Add:
```elm
import System.TypeCheck.IO as IO

type alias Meta =
    { tipe : Can.Type
    , tvar : Maybe IO.Variable
    }
```

### 4.2 Change every `Expr` variant's trailing `Can.Type` → `Meta`

**File**: `compiler/src/Compiler/AST/TypedOptimized.elm`

This is a large mechanical change. Every variant like:
```elm
| Bool A.Region Bool Can.Type
| Int  A.Region Int  Can.Type
| Call A.Region Expr (List Expr) Can.Type
```
becomes:
```elm
| Bool A.Region Bool Meta
| Int  A.Region Int  Meta
| Call A.Region Expr (List Expr) Meta
| ...
```

All ~25 variants of `Expr` must be updated.

### 4.3 Update `typeOf`

**File**: `compiler/src/Compiler/AST/TypedOptimized.elm`

Change from `expr -> ... -> tipe` to `expr -> ... -> meta.tipe` for every branch.

Add convenience:
```elm
metaOf : Expr -> Meta
-- Extract the Meta from any Expr variant

tvarOf : Expr -> Maybe IO.Variable
tvarOf expr = (metaOf expr).tvar
```

### 4.4 Update `Node` type

**File**: `compiler/src/Compiler/AST/TypedOptimized.elm`

`Node` variants also carry `Can.Type`:
```elm
type Node
    = Define Expr (EverySet (List String) Global) Can.Type
    | TrackedDefine A.Region Expr (EverySet (List String) Global) Can.Type
    | Ctor Index.ZeroBased Int Can.Type
    | Enum Index.ZeroBased Can.Type
    | Box Can.Type
    | ...
```

These should also change to `Meta` where appropriate:
- `Define` and `TrackedDefine`: change trailing `Can.Type` → `Meta`
- `Ctor`, `Enum`, `Box`: These represent constructors/enums and don't originate from typed expressions with solver vars, so they can stay as `Can.Type` (no solver var to attach). Alternatively, wrap them in `Meta` with `tvar = Nothing` for uniformity.

**Recommendation**: Keep `Ctor`/`Enum`/`Box` as `Can.Type` to minimize churn. Only change `Define`/`TrackedDefine`/`PortIncoming`/`PortOutgoing` to `Meta`.

### 4.5 Update `LocalOpt.Typed.Expression`

**File**: `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`

Current pattern:
```elm
optimize ... (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            optimizeExpr ... region tipe expr
```

New pattern:
```elm
TCan.TypedExpr { expr, tipe, tvar } ->
    let meta = { tipe = tipe, tvar = tvar }
    in optimizeExpr ... region meta expr
```

Change `optimizeExpr` and all recursive calls to accept `Meta` instead of `Can.Type`:
```elm
optimizeExpr : ... -> A.Region -> TOpt.Meta -> Can.Expr_ -> Names.Tracker TOpt.Expr
```

At each constructor site, build `Meta`:
- **When type is unchanged**: reuse the incoming `meta`
- **When type changes** (e.g., accessor, call result): build `{ tipe = newType, tvar = Nothing }`
- **Conservative**: set `tvar = Nothing` for any node whose type differs from the original canonical expression's type

### 4.6 Update `LocalOpt.Typed.Module`

**File**: `compiler/src/Compiler/LocalOpt/Typed/Module.elm`

This module builds `TOpt.Node` values (Define, Ctor, etc.). Update node construction:
- For `Define`/`TrackedDefine`: build `Meta { tipe = defType, tvar = ... }` where `tvar` comes from the TypedCanonical def's solver var
- For `Ctor`/`Enum`/`Box`: keep `Can.Type` (if we chose not to change these to `Meta`)

### 4.7 Update downstream consumers of `TOpt.Expr` and `TOpt.Node`

Files that pattern-match on `TOpt.Expr` or call `TOpt.typeOf`:

- `compiler/src/Compiler/Monomorphize/Specialize.elm` — uses `TOpt.typeOf` extensively; no change needed if `typeOf` still works
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm` — pattern matches on `TOpt.Node` variants (Define, etc.)
- `compiler/src/Compiler/Monomorphize/Closure.elm` — uses `TOpt.typeOf`
- `compiler/src/Compiler/Monomorphize/Analysis.elm` — uses `TOpt.typeOf`
- `compiler/src/Compiler/Monomorphize/State.elm` — pattern matches Node
- Various test logic files under `compiler/tests/TestLogic/`

**Strategy**: Most downstream code uses `TOpt.typeOf` which will continue to work. Code that pattern-matches `Define expr deps canType` needs updating to `Define expr deps meta` (then use `meta.tipe`).

**Search pattern**: Find all files that import `TypedOptimized` and pattern-match on its constructors:
```
grep -r "TOpt\.\(Define\|TrackedDefine\|Bool\|Int\|Float\|Call\|Function\)" compiler/src compiler/tests
```

---

## Phase 5: MonoDirect Modules

### 5.1 Create `compiler/src/Compiler/MonoDirect/State.elm`

**New file**. Mirrors `Compiler.Monomorphize.State.MonoState` but adds `SolverSnapshot`:

```elm
module Compiler.MonoDirect.State exposing (..)

type alias MonoDirectState =
    { worklist : List WorkItem
    , nodes : Dict Int Mono.MonoNode
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , currentModule : IO.Canonical
    , toptNodes : DataMap.Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , varEnv : VarEnv
    , snapshot : SolverSnapshot  -- NEW: solver state for queries
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet
    , specValueUsed : BitSet
    , renameEpoch : Int
    , schemeCache : SchemeInfoCache
    }

type WorkItem = SpecializeGlobal Mono.SpecId
```

### 5.2 Create `compiler/src/Compiler/MonoDirect/Specialize.elm`

**New file**. Mirrors `Compiler.Monomorphize.Specialize` but uses solver queries:

Key pattern for specializing an expression:
```elm
specializeExpr : TOpt.Expr -> Snapshot.LocalView -> MonoDirectState -> ( Mono.MonoExpr, MonoDirectState )
specializeExpr expr view state =
    case TOpt.tvarOf expr of
        Just tvar ->
            -- Use solver: get concrete MonoType from solver state
            let monoType = view.monoTypeOf tvar
            in ...

        Nothing ->
            -- Fallback: use TypeSubst on Can.Type
            let monoType = TypeSubst.applySubst subst (TOpt.typeOf expr)
            in ...
```

### 5.3 Create `compiler/src/Compiler/MonoDirect/Monomorphize.elm`

**New file**. Main entry point:

```elm
module Compiler.MonoDirect.Monomorphize exposing (monomorphizeDirect)

monomorphizeDirect :
    Name
    -> TypeEnv.GlobalTypeEnv
    -> SolverSnapshot
    -> TOpt.GlobalGraph
    -> Result String Mono.MonoGraph
```

Implementation:
1. Find main entry point (same as existing monomorphizer)
2. Initialize `MonoDirectState` with solver snapshot
3. Standard worklist loop: pop item → specialize via `MonoDirect.Specialize` → enqueue discoveries
4. Assemble `Mono.MonoGraph`
5. Run `Prune.pruneUnreachableSpecs` (reuse existing)

---

## Phase 6: Test-Only Pipeline

### 6.1 Add `TypedWithSnapshotArtifacts` to `Compiler.Compile`

**File**: `compiler/src/Compiler/Compile.elm`

Add:
```elm
type alias TypedWithSnapshotArtifactsData =
    { canonical : Can.Module
    , annotations : Dict.Dict Name Can.Annotation
    , typedCanonical : TCan.Module
    , typedObjects : TOpt.LocalGraph
    , typeEnv : TypeEnv.ModuleTypeEnv
    , solverSnapshot : SolverSnapshot.SolverSnapshot
    }

type TypedWithSnapshotArtifacts
    = TypedWithSnapshotArtifacts TypedWithSnapshotArtifactsData
```

Add function:
```elm
compileTypedWithSnapshot : ... -> Task Never (Result E.Error TypedWithSnapshotArtifacts)
```

Same as `compileTyped` but captures `nodeVars` and `solverState` from `runWithIds` result, builds `SolverSnapshot`, and includes it in artifacts.

### 6.2 Add test pipeline helper

**File**: `compiler/tests/TestLogic/TestPipeline.elm`

Add:
```elm
type alias MonoDirectArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    , globalGraph : TOpt.GlobalGraph
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    , solverSnapshot : SolverSnapshot.SolverSnapshot
    }

runToMonoDirect : Src.Module -> Result String MonoDirectArtifacts
```

Implementation:
1. Run `constrainWithIds` → get `(constraint, nodeVars)`
2. Run `runWithIds constraint nodeVars` → get `{ annotations, nodeTypes, nodeVars, solverState }`
3. Build `SolverSnapshot.fromSolveResult { nodeVars, solverState, ... }`
4. Run PostSolve → get fixed nodeTypes, kernelEnv
5. Build TypedCanonical with `fromCanonical canonical fixedNodeTypes nodeVars`
6. Run typed optimization → get `TOpt.LocalGraph`
7. Build global graph + type env
8. Call `MonoDirect.monomorphizeDirect "main" globalTypeEnv snapshot globalGraph`
9. Return all artifacts

### 6.3 Add MonoDirect invariant tests

**File**: `compiler/tests/TestLogic/Monomorphize/MonoDirectTest.elm` (new)

Reuse existing invariant checkers on MonoDirect output:
- `MonoCaseBranchResultType.check`
- `FullyMonomorphicNoCEcoValue.check`
- `MonoCtorLayoutIntegrity.check`
- `ClosureSpecKeyConsistency.check`
- `RegistryNodeTypeConsistency.check`
- `NoCEcoValueInUserFunctions.check`

Test structure:
```elm
suite : Test
suite =
    Test.describe "MonoDirect monomorphization invariants"
        [ test "MONO_018: Case branch result types" <| ...
        , test "MONO_001: Fully monomorphic" <| ...
        , ...
        ]
```

Each test:
1. Compile sample module via `Pipeline.runToMonoDirect`
2. Run invariant checker on resulting `monoGraph`
3. Assert no violations

---

## Phase 7: Update elm.json

**File**: `compiler/elm.json`

Add new source modules:
- `Compiler.Type.SolverSnapshot`
- `Compiler.MonoDirect.State`
- `Compiler.MonoDirect.Specialize`
- `Compiler.MonoDirect.Monomorphize`

These are source files under `compiler/src/` so they should be auto-discovered.

---

## Implementation Order

1. **Phase 1** (Solver output) — smallest change, foundational
2. **Phase 3** (TypedCanonical extension) — adds `tvar`, moderate scope
3. **Phase 4** (TypedOptimized extension) — **largest change**, requires updating all Expr/Node pattern matches across ~15+ files
4. **Phase 2** (SolverSnapshot module) — new module, depends on Phase 1 types
5. **Phase 5** (MonoDirect modules) — new modules, depends on Phases 2–4
6. **Phase 6** (Test pipeline) — wiring, depends on everything above

### Estimated File Impact

**Modified files** (~15–20):
- `compiler/src/Compiler/Type/Solve.elm`
- `compiler/src/Compiler/AST/TypedCanonical.elm`
- `compiler/src/Compiler/TypedCanonical/Build.elm`
- `compiler/src/Compiler/AST/TypedOptimized.elm`
- `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`
- `compiler/src/Compiler/LocalOpt/Typed/Module.elm`
- `compiler/src/Compiler/Compile.elm`
- `compiler/src/Compiler/Monomorphize/Specialize.elm` (pattern match updates for TOpt.Meta)
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm` (pattern match updates for Node Meta)
- `compiler/src/Compiler/Monomorphize/State.elm` (pattern match updates)
- `compiler/src/Compiler/Monomorphize/Closure.elm` (pattern match updates)
- `compiler/src/Compiler/Monomorphize/Analysis.elm` (pattern match updates)
- `compiler/tests/TestLogic/TestPipeline.elm`
- Various test logic files that match on TOpt types

**New files** (5):
- `compiler/src/Compiler/Type/SolverSnapshot.elm`
- `compiler/src/Compiler/MonoDirect/State.elm`
- `compiler/src/Compiler/MonoDirect/Specialize.elm`
- `compiler/src/Compiler/MonoDirect/Monomorphize.elm`
- `compiler/tests/TestLogic/Monomorphize/MonoDirectTest.elm`

---

## Invariants Preserved

- **TOPT_001–005**: Still about `meta.tipe` (= `Can.Type`); `tvar` is ignored by invariant tests
- **MONO_001–025**: MonoDirect output checked by same invariant checkers
- **REP_***: No representation changes
- **CGEN_***: No codegen changes
- **Production pipeline**: Completely untouched — MonoDirect is test-only
