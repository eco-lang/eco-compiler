# Plan: MErased Type + Dead-Spec Metadata + Effect-Aware Pruning

## Goal

Add per-specialization metadata (`specHasEffects`, `specValueUsed`) as BitSets during monomorphization, introduce an internal `MErased` mono type to normalize dead-value specializations, and prune unreachable specs as before (no change to pruning semantics). `specHasEffects` is tracked for future use but does not affect pruning today.

## Resolved Design Decisions

1. **Effect detection traversal**: Use `Traverse.foldExprAccFirst` to Bool. No short-circuiting helper needed — effect detection is cheap (one pattern match per expr node) and runs once per spec.

2. **What counts as effectful**: Only `MonoVarKernel _ "Debug" _ _`. No other kernel modules or `MonoManagerLeaf`. Other kernels are observationally pure from Elm's perspective; their IO effects only run when reachable from main.

3. **Registry consistency after MErased patching**: Patch *both* `reverseMapping` entries and node types together, maintaining MONO_017. Rebuild `mapping` from the patched `reverseMapping` (as Prune already does). No downstream pass creates new SpecIds from (Global, MonoType, LambdaId) after monomorphization.

4. **Effectful-but-unreachable specs**: Do NOT change pruning policy. Keep only call-graph-reachable specs; drop all unreachable ones. In Elm, unreachable specs can never execute, so their effects are dead. `specHasEffects` is tracked as future-proofing metadata but does not influence pruning today.

5. **MONO_021 and MErased**: Yes — extend MONO_021 checks to also reject `MErased` in reachable user function types (MonoDefine, MonoTailFunc, closures, tail defs). After pruning, any `MErased` remaining in the graph is a bug. Update `collectCEcoValueVars` → rename to `collectBannedTypeVars` (or similar) to also detect `MErased`.

6. **Scope of patchNodeTypesToErased**: Patch `MonoDefine` and `MonoTailFunc` only. Do NOT patch `MonoCycle` (leave CEcoValue MVars visible for the cycle specialization bug), `MonoPortIncoming`/`MonoPortOutgoing` (port ABIs must be preserved), `MonoExtern`, or `MonoManagerLeaf`.

7. **BitSet instead of Dict for metadata**: Both `specHasEffects` and `specValueUsed` are `BitSet` (set = True, not set = False). This is consistent with `inProgress` in MonoState and `live` in Prune. Much more memory-efficient than `Dict Int Int Bool` for per-SpecId boolean flags.

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/AST/Monomorphized.elm` | Add `MErased` constructor to `MonoType`, add `eraseTypeVarsToErased` helper, extend `MonoGraph` with `specHasEffects`/`specValueUsed` BitSet fields, update `monoTypeToDebugString` and `toComparableMonoTypeHelper` |
| `compiler/src/Compiler/Monomorphize/State.elm` | Add `specHasEffects`/`specValueUsed` BitSet to `MonoState`, initialize in `initState` |
| `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | Add `nodeHasEffects`, `patchNodeTypesToErased`; extend `processWorklist` to compute effects+valueUsed; extend `monomorphizeFromEntry` for MErased substitution + registry patching + extended graph construction |
| `compiler/src/Compiler/Monomorphize/Prune.elm` | Intersect `specHasEffects`/`specValueUsed` with live set when building pruned graph |
| `compiler/src/Compiler/Generate/MLIR/Types.elm` | Add crash for MErased in `monoTypeToAbi`; add crash for MErased in `monoTypeToOperand` |
| `compiler/src/Compiler/Generate/MLIR/TypeTable.elm` | Add crash for MErased in `processType` |
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Add `MErased -> []` in `getNestedTypes` |
| `compiler/src/Compiler/GlobalOpt/Staging/GraphBuilder.elm` | Add `MErased -> "Erased"` in `monoTypeToKey` |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Add `MErased -> True` in `isFullyMonomorphicType` |
| `compiler/tests/TestLogic/Monomorphize/NoCEcoValueInUserFunctions.elm` | Extend `collectCEcoValueVars` to also detect MErased; update violation messages |
| `compiler/build-xhr/tests/TestLogic/Monomorphize/NoCEcoValueInUserFunctions.elm` | Same changes (mirrored test dir) |
| `design_docs/invariants.csv` | Update MONO_021 description; add MONO_023 for MErased |

## Exhaustive MonoType Pattern Matches Requiring New `MErased` Case

These functions have exhaustive matches (no wildcard) and will cause compile errors:

| # | File | Function | Line | MErased behavior |
|---|------|----------|------|------------------|
| 1 | `Monomorphized.elm` | `monoTypeToDebugString` | 569 | `"MErased"` |
| 2 | `Monomorphized.elm` | `toComparableMonoTypeHelper` | 733 | `"Erased"` tag (same as primitives path) |
| 3 | `TypeTable.elm` | `processType` | 213 | `Utils.Crash.crash "MErased reached TypeTable.processType"` |
| 4 | `Types.elm` | `monoTypeToOperand` | 194 | `Utils.Crash.crash "MErased reached monoTypeToOperand"` |
| 5 | `Specialize.elm` | `isFullyMonomorphicType` | 2155 | `True` (erased = fully resolved, not a variable) |
| 6 | `GraphBuilder.elm` | `monoTypeToKey` | 626 | `"Erased"` |
| 7 | `Context.elm` | `getNestedTypes` | 298 | `[]` (no nested types) |

Functions with wildcard `_` that already handle MErased correctly (no changes needed):
- `forceCNumberToInt` — `_ -> monoType` (MErased unchanged, correct)
- `canUnbox` — `_ -> False` (MErased is always boxed, correct)
- `monoTypeToAbi` — `_ -> ecoValue` (but see Step 9: add explicit MErased crash *before* the wildcard)
- `collectCustomTypesFromMonoType` — wildcard returns `[]` (correct)

## Step-by-Step Implementation

### Step 1: Add `MErased` to `MonoType` + helper (`Monomorphized.elm`)

**1a.** Add constructor after `MVar`:
```elm
    | MErased  -- Internal erased type for dead-value specializations; always boxed !eco.value
```

**1b.** Update the `MonoType` doc comment (lines 155-186) to add a paragraph about MErased:
- Internal monomorphization-only type, never in source
- Replaces `MVar _ _` in specializations whose value is never used
- Always boxed `!eco.value` for layout and ABI
- Must not influence unboxing or staging
- Must not appear in any reachable spec after pruning (MONO_023)

**1c.** Add `eraseTypeVarsToErased` function and export it:
```elm
eraseTypeVarsToErased : MonoType -> MonoType
eraseTypeVarsToErased monoType =
    case monoType of
        MVar _ _ ->
            MErased

        MList t ->
            MList (eraseTypeVarsToErased t)

        MFunction args result ->
            MFunction (List.map eraseTypeVarsToErased args) (eraseTypeVarsToErased result)

        MTuple elems ->
            MTuple (List.map eraseTypeVarsToErased elems)

        MRecord fields ->
            MRecord (Dict.map (\_ t -> eraseTypeVarsToErased t) fields)

        MCustom can name args ->
            MCustom can name (List.map eraseTypeVarsToErased args)

        MErased ->
            MErased

        MInt -> MInt
        MFloat -> MFloat
        MBool -> MBool
        MChar -> MChar
        MString -> MString
        MUnit -> MUnit
```

**1d.** Add `eraseTypeVarsToErased` to the module export list.

### Step 2: Update exhaustive MonoType pattern matches

All 7 functions listed in the table above. Each gets a minimal, correct case for `MErased`. Crashes in codegen paths (processType, monoTypeToOperand), identity/safe behavior elsewhere.

### Step 3: Extend `MonoGraph` with metadata fields (`Monomorphized.elm`)

Add two BitSet fields to the `MonoGraph` record (line 351-359):
```elm
        , specHasEffects : BitSet  -- SpecIds whose node body references Debug.* kernels
        , specValueUsed : BitSet   -- SpecIds whose value is referenced via MonoVarGlobal
```

This requires importing `Compiler.Data.BitSet as BitSet exposing (BitSet)` in `Monomorphized.elm`.

All construction sites must be updated:
- `monomorphizeFromEntry` in `Monomorphize.elm` (builds `rawGraph`)
- `pruneUnreachableSpecs` in `Prune.elm` (builds pruned graph)

### Step 4: Extend `MonoState` with metadata fields (`State.elm`)

Add to `MonoState` (line 41-54):
```elm
    , specHasEffects : BitSet  -- SpecIds with Debug.* effects
    , specValueUsed : BitSet   -- SpecIds referenced as MonoVarGlobal callees
```

Initialize both to `BitSet.empty` in `initState` (line 159-172).

### Step 5: Compute `hasEffects` during specialization (`Monomorphize.elm`)

Add at bottom of module:
```elm
nodeHasEffects : Mono.MonoNode -> Bool
nodeHasEffects node =
    let
        checkExpr expr acc =
            if acc then
                True
            else
                case expr of
                    Mono.MonoVarKernel _ "Debug" _ _ ->
                        True
                    _ ->
                        False
    in
    case node of
        Mono.MonoDefine expr _ ->
            Traverse.foldExpr checkExpr False expr

        Mono.MonoTailFunc _ expr _ ->
            Traverse.foldExpr checkExpr False expr

        Mono.MonoPortIncoming expr _ ->
            Traverse.foldExpr checkExpr False expr

        Mono.MonoPortOutgoing expr _ ->
            Traverse.foldExpr checkExpr False expr

        Mono.MonoCycle defs _ ->
            List.any (\( _, expr ) -> Traverse.foldExpr checkExpr False expr) defs

        _ ->
            False
```

In `processWorklist`, for the `Mono.Global` / `Just toptNode` branch (line 246-276), after computing `monoNode`:
- Compute `neighbors = collectCallsFromNode monoNode`
- Compute `effectsHere = nodeHasEffects monoNode`
- Add to `newState`:
  ```elm
  specHasEffects =
      if effectsHere then
          BitSet.insertGrowing specId stateAfter.specHasEffects
      else
          stateAfter.specHasEffects
  ```

For the `Mono.Accessor` branch (line 222-234):
- Accessors are always pure, no BitSet update needed (absent = not effectful).

For the `Nothing` (extern) branch (line 238-248):
- Externs are treated as effect-free, no BitSet update needed.

### Step 6: Compute `valueUsed` during specialization (`Monomorphize.elm`)

In `processWorklist`, in all three branches that produce a `newState`, after computing `neighbors` (= `collectCallsFromNode monoNode`):
```elm
specValueUsed1 =
    List.foldl
        (\calleeId acc -> BitSet.insertGrowing calleeId acc)
        stateAfter.specValueUsed
        neighbors
```
Add `specValueUsed = specValueUsed1` to `newState`.

For the extern branch (`neighbors = []`), just propagate unchanged: `specValueUsed = state2.specValueUsed`.

### Step 7: MErased substitution for dead-value specs (`Monomorphize.elm`)

In `monomorphizeFromEntry` (line 71-126), after `finalState = processWorklist stateWithMain`:

**7a.** Compute `valueUsedWithMain`:
```elm
valueUsedWithMain =
    case mainSpecId of
        Just sid ->
            BitSet.insertGrowing sid finalState.specValueUsed
        Nothing ->
            finalState.specValueUsed
```

**7b.** Patch nodes:
```elm
patchedNodes =
    Dict.map
        (\specId node ->
            if BitSet.member specId valueUsedWithMain then
                node
            else
                patchNodeTypesToErased node
        )
        finalState.nodes
```

**7c.** Define `patchNodeTypesToErased`:
```elm
patchNodeTypesToErased : Mono.MonoNode -> Mono.MonoNode
patchNodeTypesToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine expr (Mono.eraseTypeVarsToErased t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc
                (List.map (\( name, ty ) -> ( name, Mono.eraseTypeVarsToErased ty )) params)
                expr
                (Mono.eraseTypeVarsToErased t)

        -- Do NOT patch: cycles (preserve MONO_021 visibility), ports (ABI obligations),
        -- externs/managers (kernel ABI), ctors/enums (no MVars in practice)
        _ ->
            node
```

**7d.** Patch registry to maintain MONO_017:
```elm
patchedRegistry =
    let
        oldReg = finalState.registry
        newReverseMapping =
            Array.indexedMap
                (\specId entry ->
                    case entry of
                        Just ( global, _, maybeLambda ) ->
                            case Dict.get identity specId patchedNodes of
                                Just patchedNode ->
                                    Just ( global, Mono.nodeType patchedNode, maybeLambda )
                                Nothing ->
                                    entry
                        Nothing ->
                            Nothing
                )
                oldReg.reverseMapping

        newMapping =
            List.foldl
                (\( specId, maybeEntry ) acc ->
                    case maybeEntry of
                        Just ( global, monoType, maybeLambda ) ->
                            let
                                key = Mono.toComparableSpecKey (Mono.SpecKey global monoType maybeLambda)
                            in
                            Dict.insert identity key specId acc
                        Nothing ->
                            acc
                )
                Dict.empty
                (Array.toIndexedList newReverseMapping)
    in
    { nextId = oldReg.nextId
    , mapping = newMapping
    , reverseMapping = newReverseMapping
    }
```

**7e.** Build `rawGraph` from patched data:
```elm
rawGraph =
    Mono.MonoGraph
        { nodes = patchedNodes
        , registry = patchedRegistry
        , main = mainInfo
        , ctorShapes = Dict.empty
        , nextLambdaIndex = finalState.lambdaCounter
        , callEdges = finalState.callEdges
        , specHasEffects = finalState.specHasEffects
        , specValueUsed = valueUsedWithMain
        }
```

### Step 8: Prune metadata fields (`Prune.elm`)

In `pruneUnreachableSpecs` (line 72-143), after computing `live` BitSet and existing filtered dicts:

Intersect the two BitSets with the `live` set. BitSet doesn't have a direct `intersection` helper, so build pruned sets by iterating live specIds:

```elm
-- Prune specHasEffects and specValueUsed to only live SpecIds.
-- Since dead specIds are removed from nodes/callEdges/registry, the metadata
-- BitSets should only retain bits for live specs. We can simply keep them as-is
-- because a stale bit for a pruned specId is harmless (no node exists to look it up),
-- but for hygiene we mask them against live.
specHasEffects1 =
    BitSet.fromSize size
        |> (\bs ->
                Dict.foldl compare
                    (\specId _ acc ->
                        if BitSet.member specId record.specHasEffects then
                            BitSet.insert specId acc
                        else
                            acc
                    )
                    bs
                    nodes1
           )

specValueUsed1 =
    BitSet.fromSize size
        |> (\bs ->
                Dict.foldl compare
                    (\specId _ acc ->
                        if BitSet.member specId record.specValueUsed then
                            BitSet.insert specId acc
                        else
                            acc
                    )
                    bs
                    nodes1
           )
```

Alternatively, since stale bits in a BitSet for pruned specIds are harmless (there's no node to look them up against), we can simply pass them through unchanged. The cleaner option is to pass them through:

```elm
-- Stale bits for pruned specIds are harmless — no node exists to reference them.
-- Pass BitSets through unchanged for simplicity.
specHasEffects1 = record.specHasEffects
specValueUsed1 = record.specValueUsed
```

**Decision**: Pass through unchanged (simpler, no correctness issue). If hygiene becomes important later, add a `BitSet.intersect` utility.

Include them when constructing the final `MonoGraph`:
```elm
Mono.MonoGraph
    { nodes = nodes1
    , main = record.main
    , registry = registry1
    , ctorShapes = ctorShapes1
    , nextLambdaIndex = record.nextLambdaIndex
    , callEdges = callEdges1
    , specHasEffects = record.specHasEffects
    , specValueUsed = record.specValueUsed
    }
```

No change to pruning logic itself — `live` is still computed purely from call-graph reachability from main.

### Step 9: Codegen crash guards (`Types.elm`)

In `monoTypeToAbi` (line 158-175), add an explicit case *before* the wildcard:
```elm
Mono.MErased ->
    Utils.Crash.crash "MErased leaked to monoTypeToAbi — dead-value spec not pruned"
```

The `monoTypeToOperand` and `processType` crashes are already handled in Step 2 (exhaustive match updates).

### Step 10: Extend MONO_021 test to reject MErased

**File:** `compiler/tests/TestLogic/Monomorphize/NoCEcoValueInUserFunctions.elm` (and mirrored `build-xhr` copy)

**10a.** Rename `collectCEcoValueVars` to `collectBannedTypeMarkers` (or keep the name and extend its semantics). Add `MErased` detection:
```elm
collectCEcoValueVars monoType =
    case monoType of
        Mono.MVar name Mono.CEcoValue ->
            [ name ]

        Mono.MErased ->
            [ "<MErased>" ]

        -- ... rest unchanged ...
```

**10b.** Update violation messages to say "CEcoValue MVar or MErased" instead of just "CEcoValue MVar".

**10c.** Update the module doc comment to mention MErased as a banned marker in reachable user functions.

### Step 11: Update invariants (`design_docs/invariants.csv`)

**11a.** Update MONO_021: Add mention that `MErased` is also banned in reachable user function types, same as `MVar _ CEcoValue`.

**11b.** Add MONO_023:
```
MONO_023;Monomorphization;Types;documented;MErased must not appear in any MonoType that reaches MLIR codegen (monoTypeToAbi, monoTypeToOperand, processType). Its presence indicates a dead-value specialization whose type was normalized by eraseTypeVarsToErased but was not properly pruned by MONO_022. Guarded by crash assertions in codegen.;Compiler.Generate.MLIR.Types|Compiler.Generate.MLIR.TypeTable
```

## Risk Assessment

| Risk | Level | Mitigation |
|------|-------|------------|
| Adding `MErased` constructor breaks exhaustive matches | Low | Step 2 fixes all 7; wildcard functions are already safe |
| Adding metadata fields to MonoGraph/MonoState | Low | Data-only; no logic change; all construction sites updated |
| `valueUsed` computation correctness | Medium | Direct callees marked during worklist; transitive reachability handled by existing prune pass; main always marked used |
| MErased substitution affecting live specs | Medium | Guard: `if isUsed then node else patch`. Only patches nodes where `valueUsed == False` |
| Registry consistency after patching | Medium | Rebuild both `reverseMapping` and `mapping` from patched node types; MONO_017 maintained |
| MErased leaking to codegen | Low | Triple-guarded: (1) only dead-value specs get MErased, (2) pruning removes unreachable specs, (3) crash assertions in codegen |

## Testing Strategy

1. **Compiler compiles**: Adding MErased to all exhaustive matches ensures no compile errors
2. **Existing elm-test-rs tests**: `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — MONO_021 tests pass (MErased only on dead specs, which are pruned before tests check)
3. **E2E tests**: `cmake --build build --target check` — all codegen tests pass (MErased never reaches codegen for working programs)
4. **Manual verification**: Inspect a program with an unused polymorphic function, verify:
   - Its spec gets `valueUsed` bit not set
   - Its node type gets MErased substitution
   - It gets pruned (unreachable from main)
   - No MONO_021 violation (it's gone after pruning)
