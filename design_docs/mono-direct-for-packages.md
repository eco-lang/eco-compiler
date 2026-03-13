Below is a revised design that matches the **current code** more closely and focuses on what still needs to change to reach the original goals:
- Per-module solver snapshots (for packages too),
- Multi-module `MonoDirect`,
- No reliance on the old monomorphizer as a backstop.

Where the code already matches the previous design, I'll be brief. Where the delta report shows gaps or architectural differences, I go into more detail and give concrete code sketches.
---
## 1. Recap: Current State vs Target
### 1.1 What's already close to design

- **SolverSnapshot exists** and wraps the solver state (`solverState : { descriptors, pointInfo, weights }`) and `nodeVars`. Helpers like `withLocalUnification`, `LocalView`, `lookupDescriptor`, `resolveVariable`, `specializeFunction` live in `SolverSnapshot.elm` instead of `Solve.elm`. Functionally, this matches the idea of a local solver snapshot + unification API.
- **TypedCanonical** now carries both `ExprTypes` and `ExprVars`, and `TypedExpr` has a `tvar` field. This matches the design.
- **TypedOptimized** has a `Meta { tipe, tvar }` and all 27 Expr variants carry Meta; `LocalOpt.Typed` propagates `tvar`. Synthesized expressions use `tvar = Nothing`. This matches.
- **MonoDirect** exists, with a worklist and specialization logic, for a single module. It uses `SolverSnapshot.withLocalUnification` + `LocalView` to specialize.
### 1.2 What's missing or different

1. **No multi-module MonoDirect**
   - `monomorphizeDirect` currently takes a single module's `TOpt.GlobalGraph` and `SolverSnapshot`, not a `Dict ModuleName (TOpt.GlobalGraph, SolverSnapshot)`.
   - There's no way to resolve cross-module references using multiple snapshots.
2. **No solver snapshot persistence in module artifacts**
   - `TypedModuleArtifact` only has `{ typedGraph : TOpt.LocalGraph, typeEnv }`.
   - `.ecot` (or equivalent) files don't store `SolverSnapshot`, and there's no binary encoder/decoder for it.
   - Snapshots exist only in memory in tests.

3. **Typecheck API doesn't surface snapshot for production**
   - `Compile.typeCheckTyped` extracts solver state from `runWithIds` but discards it for the main compile pipeline; only the test pipeline pulls it through.

4. **Phantom erasure is post-hoc and reachability-based, not solver-integrated**
   - The design spoke of phantom detection in `withLocalUnification` via solver analysis; the implementation relies on:
     - `isValueUsed` BitSets,
     - `containsCEcoMVar` on specialization keys,
     - `eraseCEcoVarsToErased` in `Monomorphized.elm`.
   - It's *not* wired into `monoTypeOf` inside `withLocalUnification`.
   - **Note:** The standard monomorphizer also calls `fillUnconstrainedCEcoWithErased` (from `Monomorphize.TypeSubst`) at 3 call sites during specialization. MonoDirect does **not** replicate this step; it relies entirely on post-hoc erasure during pruning.

5. **Tests**
   - `TestPipeline.runToMonoDirect` exists and is more comprehensive than originally designed.
   - `MonoDirectTest.elm` smoke-tests compilation.
   - `MonoDirectComparisonTest.elm` compares MonoDirect vs standard monomorphizer with alpha-normalized equivalence.
   - **MONO_* invariant checks are not run on MonoDirect output** yet.

The rest of the design will focus primarily on fixing (1)-(3) and (5). For phantom erasure (4) we'll align the design with the *existing* post-hoc strategy rather than proposing another architecture.
---
## 2. Solver Snapshot: Align Design With Actual `SolverSnapshot.elm`
### 2.1 Current shape

From the delta:
- `Solve.elm` does **not** define `SolverCore`; instead, runWithIds returns an inline `solverState : { descriptors, pointInfo, weights }`.
- `SolverSnapshot.elm` defines its own `SolverState` alias wrapping that record, and `SolverSnapshot` holds:
  ```elm
  type alias SolverSnapshot =
      { state : SolverState
      , nodeVars : Array (Maybe TypeVar)
      , annotationVars : DMap.Dict String Name.Name TypeVar
      }
  ```

- Helper functions like `snapshotToIoState`, `relaxRigidVar`, `lookupDescriptor`, `resolveVariable`, `specializeFunction` are implemented *inside* `SolverSnapshot.elm`, and **call `Unify.unify` / `Type.toCanTypeBatch` directly**.
This is organizationally different but functionally equivalent to what we wanted.
### 2.2 Design: keep solver helpers in `SolverSnapshot.elm`

We accept the current organization:
- `SolverState` is the opaque solver graph descriptor/internal state.
- All unification and descriptor operations we need for MonoDirect are implemented in `SolverSnapshot.elm`, not exported from `Solve.elm`.

**Required adjustments to design:**

1. Update references from `Solve.SolverCore` to `SolverSnapshot.SolverState`.
2. Accept that:
   ```elm
   withLocalUnification :
       SolverSnapshot
       -> List Variable
       -> List (Variable, Variable)
       -> (LocalView -> a)
       -> a
   ```

   is implemented by:

   - `snapshotToIoState` (turn snapshot state into an IO-friendly env),
   - calling `Unify.unify` with that env,
   - using `Type.toCanTypeBatch` to compute `Can.Type` for variables.
3. Codify `LocalView` in design as:
   ```elm
   type alias LocalView =
       { typeOf : Variable -> Can.Type
       , monoTypeOf : Variable -> Mono.MonoType
       }
   ```

   implemented in terms of:

   - `typeOf v = resolveVariable snapshotState v |> toCanType` via `Type.toCanTypeBatch`,
   - `monoTypeOf` using existing `canTypeToMonoType` helpers (see below).
**Implementation detail for monoTypeOf (code sketch):**
```elm
monoTypeOf : SolverSnapshot -> Variable -> Mono.MonoType
monoTypeOf snap v =
    let
        canTypes : Array (Maybe Can.Type)
        canTypes =
            SolverSnapshot.toCanTypes snap  -- already exists or can be added

        canType =
            Array.get (SolverSnapshot.varIndex v) canTypes
                |> Maybe.andThen identity
                |> Maybe.withDefault
                    (Debug.crash "monoTypeOf: missing type for var")

    in
    Compiler.Monomorphize.TypeSubst.canTypeToMonoType canType
```

You already have `specializeFunction` in `SolverSnapshot.elm`; this can be reused or generalized for `monoTypeOf`.
---
## 3. Typechecking API: Expose Snapshot to Artifacts
### 3.1 Current situation

- `typeCheckTyped` *internally* has access to `solverState` from `runWithIds` (as the delta report says) but does **not** return it in its result record.
- The test pipeline pulls out solver state separately; the main compile path does not.
### 3.2 Design: extend `typeCheckTyped` result

We adjust the **public record** returned by `typeCheckTyped` so that it includes `solverSnapshot`, while keeping existing fields.

**File:** `compiler/src/Compiler/Compile.elm`

Current type (the stored artifact is a newtype wrapper around `TypedArtifactsData`):
```elm
type alias TypedArtifactsData =
    { canonical : Can.Module
    , annotations : Dict.Dict Name Can.Annotation
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph
    , typeEnv : TypeEnv.ModuleTypeEnv
    }

type TypedArtifacts
    = TypedArtifacts TypedArtifactsData
```

Note: `typedCanonical` and `kernelEnv` exist transiently inside `typeCheckTyped` but are **not** stored in `TypedArtifacts`.

**Change:** extend `TypedArtifactsData` with `solverSnapshot`:
```elm
type alias TypedArtifactsData =
    { canonical : Can.Module
    , annotations : Dict.Dict Name Can.Annotation
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph
    , typeEnv : TypeEnv.ModuleTypeEnv
    , solverSnapshot : SolverSnapshot.SolverSnapshot  -- NEW
    }
```

In `typeCheckTyped`, the solver state is already destructured from the `runWithIds` result. We construct the snapshot and thread it through:
```elm
Ok { annotations, annotationVars, nodeTypes, nodeVars, solverState } ->
    let
        postSolveResult =
            PostSolve.postSolve annotations canonical nodeTypes

        fixedNodeTypes =
            postSolveResult.nodeTypes

        kernelEnv =
            postSolveResult.kernelEnv

        typedCanonical =
            TCanBuild.fromCanonical canonical fixedNodeTypes nodeVars

        snapshot =
            SolverSnapshot.fromSolveResult
                { solverState = solverState
                , nodeVars = nodeVars
                , annotationVars = annotationVars
                }
    in
    Ok
        { annotations = everyDictToDict annotations
        , typedCanonical = typedCanonical
        , nodeTypes = fixedNodeTypes
        , kernelEnv = kernelEnv
        , nodeVars = nodeVars
        , annotationVars = annotationVars
        , solverSnapshot = snapshot
        }
```

You already have this logic *in tests*; the design change is to make `solverSnapshot` a first-class field in `TypedArtifactsData` so that:
- the **package builder** code can persist it (Section 4),
- and the **app build** code can load it for MonoDirect.
---
## 4. Module Artifacts: Persisting SolverSnapshot
### 4.1 Current artifact

**File:** `compiler/src/Compiler/AST/TypedModuleArtifact.elm`

The current definition is:
```elm
type alias TypedModuleArtifact =
    { typedGraph : TOpt.LocalGraph
    , typeEnv : TypeEnv.ModuleTypeEnv
    }
```

Note: this uses `TOpt.LocalGraph` (per-module), not `TOpt.GlobalGraph` (cross-module merged). The `LocalGraph` is what gets persisted to disk; conversion to `GlobalGraph` happens later at link time.
### 4.2 Design: extend `TypedModuleArtifact` with snapshot

**File:** `compiler/src/Compiler/AST/TypedModuleArtifact.elm`

New type:
```elm
type alias TypedModuleArtifact =
    { typedGraph : TOpt.LocalGraph
    , typeEnv : TypeEnv.ModuleTypeEnv
    , solverSnapshot : SolverSnapshot.SolverSnapshot
    , annotations : Dict Name Annotation      -- optional, but useful
    , exports : InterfaceInfo                 -- as needed for package loading
    }
```

This change is central to the design:
- Every compiled module (library or app) will carry its `SolverSnapshot` in its typed artifact.
### 4.3 Write path: persist snapshot into `.ecot`

Where you currently write a module's typed artifact:
```elm
writeTypedArtifact : ModuleName -> TypedArtifacts -> IO ()
writeTypedArtifact name artifacts =
    let
        moduleArtifact : TypedModuleArtifact
        moduleArtifact =
            { typedGraph = artifacts.typedObjects
            , typeEnv = artifacts.typeEnv
            }
    in
    ArtifactStore.save name moduleArtifact
```

Change to:
```elm
writeTypedArtifact name artifacts =
    let
        moduleArtifact : TypedModuleArtifact
        moduleArtifact =
            { typedGraph = artifacts.typedObjects
            , typeEnv = artifacts.typeEnv
            , solverSnapshot = artifacts.solverSnapshot
            , annotations = artifacts.annotations
            , exports = computeExports artifacts
            }
    in
    ArtifactStore.save name moduleArtifact
```

**Serialization detail:**
- `SolverSnapshot` must implement `encode : SolverSnapshot -> Bytes` and `decode : Bytes -> Result Decode.Error SolverSnapshot`.

Rough sketch:
```elm
encodeSnapshot : SolverSnapshot -> Encode.Encoder
encodeSnapshot snapshot =
    Encode.object
        [ ( "nodeVars", encodeNodeVars snapshot.nodeVars )
        , ( "annotationVars", encodeAnnotationVars snapshot.annotationVars )
        , ( "descriptors", encodeDescriptors snapshot.state.descriptors )
        , ( "pointInfo", encodePointInfo snapshot.state.pointInfo )
        , ( "weights", encodeWeights snapshot.state.weights )
        ]

decodeSnapshot : Decode.Decoder SolverSnapshot
decodeSnapshot =
    Decode.map5
        (\nodeVars annotationVars descriptors pointInfo weights ->
            { state = { descriptors = descriptors, pointInfo = pointInfo, weights = weights }
            , nodeVars = nodeVars
            , annotationVars = annotationVars
            }
        )
        (Decode.field "nodeVars" decodeNodeVars)
        (Decode.field "annotationVars" decodeAnnotationVars)
        (Decode.field "descriptors" decodeDescriptors)
        (Decode.field "pointInfo" decodePointInfo)
        (Decode.field "weights" decodeWeights)
```

This encoding must match the actual `SolverSnapshot` shape: `{ state : { descriptors, pointInfo, weights }, nodeVars, annotationVars }`.
### 4.4 Read path: load snapshot from `.ecot`

Where you currently load a typed module artifact:
```elm
loadTypedArtifact : ModuleName -> IO TypedModuleArtifact
```

Make sure `TypedModuleArtifact` now carries `solverSnapshot`, and your decode function populates it.
This gives you, for every module:
```elm
(typedGraph : TOpt.LocalGraph, solverSnapshot : SolverSnapshot.SolverSnapshot)
```

which is exactly what MonoDirect needs (after converting `LocalGraph` to `GlobalGraph` at link time).
---
## 5. MonoDirect: Evolve to Multi-Module
### 5.1 Current signature

The current implementation is single-module:
```elm
monomorphizeDirect :
    Name
    -> TypeEnv.GlobalTypeEnv
    -> SolverSnapshot.SolverSnapshot
    -> TOpt.GlobalGraph
    -> Result String Mono.MonoGraph
```
### 5.2 New multi-module signature

We want:
```elm
monomorphizeDirect :
    ModuleName
    -> Name
    -> Dict ModuleName ( TOpt.GlobalGraph, SolverSnapshot.SolverSnapshot )
    -> TypeEnv.GlobalTypeEnv
    -> Result String Mono.MonoGraph
```

This allows specialization across **all** modules in the build, including packages.
### 5.3 State: from single module to moduleMap

Current `MonoDirectState` (from `compiler/src/Compiler/MonoDirect/State.elm`) has:
```elm
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
    , localMulti : List LocalMultiState
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet
    , specValueUsed : BitSet
    , renameEpoch : Int
    , snapshot : SolverSnapshot
    }
```

The current `WorkItem` is a union type, not a record:
```elm
type WorkItem
    = SpecializeGlobal Mono.SpecId
```

The `SpecId` is resolved to a `(Global, MonoType, Maybe LambdaId)` via registry lookup. Module info is already embedded in `Global`:
```elm
type Global
    = Global IO.Canonical Name
    | Accessor Name
```

And `SpecKey` is also a union type:
```elm
type SpecKey
    = SpecKey Global MonoType (Maybe LambdaId)
```

Since `Global` already carries `IO.Canonical` (the module identifier), `SpecKey` **already contains module info** through the `Global` type. There is no need to add a separate `ModuleName` field.

We extend the state to hold a module map instead of a single module's graph + snapshot:
```elm
type alias MonoDirectState =
    { moduleMap :
        Dict ModuleName
            { graph : TOpt.GlobalGraph
            , snapshot : SolverSnapshot.SolverSnapshot
            }
    , typeEnv : TypeEnv.GlobalTypeEnv
    , worklist : List WorkItem
    , inProgress : BitSet
    , scheduled : BitSet
    , nodes : Dict Int Mono.MonoNode
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet
    , specValueUsed : BitSet
    , renameEpoch : Int
    , currentGlobal : Maybe Mono.Global
    , varEnv : VarEnv
    , localMulti : List LocalMultiState
    }
```

The key changes are replacing `toptNodes`, `snapshot`, and `currentModule` with `moduleMap`. The `WorkItem` can remain as `SpecializeGlobal SpecId` since the module can be determined from the registry's `Global` for that `SpecId`.
### 5.4 Resolving globals and modules

When MonoDirect encounters a global reference:
- The current `enqueueSpec` function takes a `Mono.Global` and enqueues a `SpecializeGlobal SpecId`. The `Global` already carries `IO.Canonical` (module name).
- In a multi-module world, the processing loop extracts the module name from the `Global` in the registry's reverse mapping, then looks up the appropriate `(graph, snapshot)` from `moduleMap`.

No change to `SpecKey` is needed since `Global` already embeds `IO.Canonical`.
### 5.5 Using per-module snapshots

When processing a `WorkItem`:
```elm
processWorkItem : WorkItem -> MonoDirectState -> MonoDirectState
processWorkItem (SpecializeGlobal specId) state =
    let
        ( global, monoType, maybeLambda ) =
            Registry.lookupSpecKey specId state.registry

        moduleName =
            globalModuleName global

        moduleEntry =
            Dict.get moduleName state.moduleMap
                |> Maybe.withDefault (Debug.crash "MonoDirect: missing module")

        graph = moduleEntry.graph
        snapshot = moduleEntry.snapshot

        globalNode =
            TOpt.lookupGlobal (globalName global) graph
                |> Maybe.withDefault (Debug.crash "MonoDirect: missing global")

        rootVar =
            TOpt.globalTVar globalNode
                |> Maybe.withDefault (Debug.crash "MonoDirect: no tvar for global")
    in
    SolverSnapshot.withLocalUnification snapshot [ rootVar ] []
        (\view ->
            let
                monoNode =
                    specializeGlobalNode moduleName (globalName global) view globalNode state

                state1 =
                    registerNode specId monoNode state
            in
            state1
        )
```

Cross-module calls are then handled by `enqueueSpec` creating new `SpecializeGlobal` entries; the processing loop picks up the correct module via the `Global`'s `IO.Canonical`.
---
## 6. Phantom Erasure: Align Design to Current Implementation

The delta report shows:
- There is **no `Solve.isPhantomVar`**.
- Erasure is done **post-hoc** during pruning:
  - `isValueUsed` BitSet tracks whether the function's value is used,
  - `containsCEcoMVar` inspects the MonoType key,
  - `eraseCEcoVarsToErased` converts CEcoValue MVars to `MErased`.

Given that this is working and already integrated into MonoDirect's pruning logic, the most accurate design is to **document and refine that mechanism**, not replace it.
### 6.1 Current reachable-based erasure pattern (high-level)

1. For each specialization, you track:
   - `specValueUsed : BitSet` -- is the value ever consumed?
   - `specHasEffects : BitSet` -- is it effectful even if value is unused?
2. After building the graph and computing reachability and these flags:

   - If `specValueUsed[specId]` is false, treat all type variables as irrelevant, and run a global `eraseTypeVarsToErased` on that specialization's types.
   - If the key MonoType contains `CEcoValue` MVars and they are only in value positions, run `eraseCEcoVarsToErased`.

3. These operations traverse `Mono.MonoType` structures, replacing `MVar _ CEcoValue` with `MErased` where appropriate.
### 6.2 Known divergence from standard monomorphizer

The standard monomorphizer calls `fillUnconstrainedCEcoWithErased` (from `Compiler.Monomorphize.TypeSubst`) at 3 call sites during specialization. This fills unconstrained `CEcoValue` type variables with `MErased` *during* specialization, before post-hoc pruning.

MonoDirect does **not** replicate this step. It relies entirely on post-hoc erasure during pruning. This is intentional for now: the post-hoc approach is simpler and the comparison tests (`MonoDirectComparisonTest.elm`) verify equivalence. If edge cases arise where post-hoc erasure is insufficient, `fillUnconstrainedCEcoWithErased` can be integrated into MonoDirect's specialization phase.
### 6.3 Design: codify this as the expected phantom behavior

We update the design goal from:
> "Erasure inside withLocalUnification ('by construction')"

to:

> "Erasure is performed structurally over MonoTypes after specialization and reachability analysis, using `specValueUsed` and `containsCEcoMVar` as guides. No separate 'old monomorphizer backstop' is used; MonoDirect is responsible for producing correct final MErased placements."

No change to the current erasure code is required to meet the design goals, as long as:
- **All reachable specializations** have gone through this erasure step,
- MONO_020-MONO_024 invariants hold on MonoDirect graphs.
---
## 7. Tests: From Smoke & Comparison to Invariants
### 7.1 Current test situation

The test pipeline (`TestPipeline.elm`) provides 6 pipeline stages:
1. Canonicalization: Source AST -> Canonical AST
2. Type Checking: Canonical -> annotations + nodeTypes (pre-PostSolve)
3. PostSolve: Fix Group B types, compute kernel env
4. Typed Optimization: TypedCanonical -> LocalGraph
5. Monomorphization: LocalGraph -> GlobalGraph -> MonoGraph
6. MLIR Generation: MonoGraph -> MlirModule

Entry points exist for each stage (`runToPostSolve`, `runToTypedOpt`, `runToMono`, `runToMonoDirect`, `runToGlobalOpt`, `runToMlir`).

Current MonoDirect test coverage:
- `MonoDirectTest.elm` exists and checks "does MonoDirect compile successfully?".
- `MonoDirectComparisonTest.elm` compares MonoDirect output with the standard monomorphizer via alpha-normalized equivalence.
- **MONO_* invariant checks are not yet applied to MonoDirect output.**
### 7.2 Design: extend tests to run MONO_* invariants

You already have MONO_* invariant checkers used on standard MonoGraphs. The next steps:
1. **Expose MonoDirect in the same test harness** as standard monomorphization:

   - For a given sample module, run both pipelines:
     - `runToMono` (existing),
     - `runToMonoDirect` (new).
   - For now, keep the comparison tests; they're valuable.

2. **Add tests that apply MONO_* invariant suites directly to MonoDirect output:**

   For example:
   ```elm
   module TestLogic.MonoDirect.MonoCaseBranchResultTypeTest exposing (tests)

   import Test exposing (..)
   import Expect
   import TestPipeline
   import TestLogic.Monomorphize.MonoCaseBranchResultType as Check

   tests : Test
   tests =
       describe "MonoDirect: MonoCase branch result types"
           [ test "all branches match result type" <|
               \_ ->
                   case TestPipeline.runToMonoDirect sampleInput of
                       Err err ->
                           Expect.fail (Debug.toString err)

                       Ok { monoGraph } ->
                           case Check.checkMonoCaseBranchResultTypes monoGraph of
                               [] ->
                                   Expect.pass

                               problems ->
                                   Expect.fail (Debug.toString problems)
           ]
   ```

   Repeat for:

   - MONO_011/019 (graph hygiene, lambdaId uniqueness),
   - MONO_020-MONO_024 (no CEcoValue/MErased in forbidden positions),
   - MONO_018 (case branch result types),
   - etc.
3. **Plan for multi-module tests**:

   Once module artifacts are being saved and loaded with snapshots, add tests where:

   - You compile a small "package" module, persist its typed artifact+snapshot.
   - Then compile an app module that imports it, read its artifact, and run `runToMonoDirect` on the app, verifying invariants.

This gives you a robust signal when the multi-module & snapshot persistence work is complete and correct.
---
## 8. Summary of Major Code Changes Still Needed

Here is a concise checklist of adjustments required to bring the implementation up to the design goals:
1. **Typechecking & artifacts**
   - Extend `TypedArtifactsData` to include `solverSnapshot`.
   - Ensure `typeCheckTyped` populates this field from `runWithIds` -> `SolverSnapshot.fromSolveResult`.
   - Extend `TypedModuleArtifact` (in `compiler/src/Compiler/AST/TypedModuleArtifact.elm`) to include `solverSnapshot` (and optionally `annotations`/`exports`).

2. **Snapshot persistence**
   - Implement `encodeSnapshot` / `decodeSnapshot` in `SolverSnapshot.elm` (or in a companion module).
   - Modify artifact write path to serialize `solverSnapshot` into `.ecot`.
   - Modify artifact read path to deserialize `solverSnapshot`.

3. **Multi-module MonoDirect**
   - Change `monomorphizeDirect` signature to accept:

     ```elm
     ModuleName
     -> Name
     -> Dict ModuleName ( TOpt.GlobalGraph, SolverSnapshot )
     -> TypeEnv.GlobalTypeEnv
     ```

   - Adjust `MonoDirectState` to hold `moduleMap` and per-module snapshots, replacing `toptNodes`, `snapshot`, and `currentModule`.
   - `WorkItem` can remain as `SpecializeGlobal SpecId` since module info is already embedded in `Mono.Global` (via `IO.Canonical`).
   - Update specialization logic to:
     - extract the module from the `Global` in the registry for each work item,
     - look up the correct `(graph, snapshot)` from `moduleMap`,
     - enqueue cross-module specializations correctly.

4. **Phantom erasure (design alignment)**
   - Document current `specValueUsed` + `eraseCEcoVarsToErased` behavior as the canonical phantom handling for MonoDirect.
   - Note the `fillUnconstrainedCEcoWithErased` gap vs standard monomorphizer; monitor comparison tests for edge cases.
   - Ensure this pass is always run for MonoDirect graphs before tests and backend usage.

5. **Tests**
   - Add MONO_* invariant suites for MonoDirect output, paralleling existing tests for the standard monomorphizer.
   - Add multi-module tests once snapshot persistence and moduleMap integration are in place.

Once these changes are in, MonoDirect will match the design goals:

- Every module, including packages, has a persisted solver snapshot.
- MonoDirect is fully multi-module and solver-driven, without relying on the old monomorphizer as a backstop.
- All monomorphization invariants are enforced on MonoDirect output, giving you the confidence to switch over when ready.
