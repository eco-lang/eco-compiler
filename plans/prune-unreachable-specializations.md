# Plan: Prune Unreachable Specializations from MonoGraph

## Goal

After monomorphization, remove all specializations from `MonoGraph` that are not reachable from the main entry point via `callEdges`. This ensures the graph handed to GlobalOpt and MLIR contains **only concrete specializations that matter**, dropping any "template-like" or speculative specializations that were created but never used.

## Context

Relevant structures (all in `compiler/src/Compiler/AST/Monomorphized.elm`):
- `MonoGraph`: wraps `nodes : Dict Int Int MonoNode`, `callEdges : Dict Int Int (List Int)`, `main : Maybe MainInfo`, `registry : SpecializationRegistry`, `ctorShapes : Dict (List String) (List String) (List CtorShape)`
- `SpecializationRegistry`: `{ nextId : Int, mapping : Dict String String SpecId, reverseMapping : Array (Maybe (Global, MonoType, Maybe LambdaId)) }`
- `SpecId = Int` (indexes into `reverseMapping`)
- `MainInfo = StaticMain SpecId`
- `callEdges` populated by `collectCallsFromNode` during worklist processing — captures all `MonoVarGlobal` references (functions, ctors, enums, ports, etc.), not just call sites

Integration point: `monomorphizeFromEntry` in `compiler/src/Compiler/Monomorphize/Monomorphize.elm` (line ~74).

`computeCtorShapesForGraph` (line ~390 in Monomorphize.elm) calls `Analysis.collectAllCustomTypes` which iterates over `nodes` dict. It also depends on `buildCompleteCtorShapes` and `buildCtorShapeFromUnion` (both in Monomorphize.elm), which use `TypeSubst.applySubst`.

---

## Step-by-step Plan

### Step 1: Add invariant MONO_022 to `design_docs/invariants.csv`

Add after MONO_021 (line ~160):

```
MONO_022;Monomorphization;Graph;documented;After monomorphization and specialization-pruning every SpecId in SpecializationRegistry.mapping or MonoGraph.nodes is reachable from the main specialization via the callEdges graph. The reachable set is the least fixed point starting from mainSpecId and following all MonoVarGlobal edges collected in callEdges. No unused template specializations remain in MonoGraph. CtorShapes are also pruned to only include types referenced by reachable nodes.;Compiler.Monomorphize.Prune
```

### Step 2: Update MONO_011 prose in `invariants.csv`

Tighten MONO_011 (line 142) to reference MONO_022 and remove the "or flagged" escape hatch:

```
MONO_011;Monomorphization;Graph;documented;MonoGraph is closed and hygienic every MonoVarLocal refers to a binder in scope every MonoVarGlobal and SpecId refers to an existing MonoNode and after applying the specialization-pruning pass (MONO_022) there are no unreachable specializations in the registry or nodes;Compiler.AST.Monomorphized|Compiler.Monomorphize.Prune
```

### Step 3: Move `computeCtorShapesForGraph` to `Analysis.elm`

Move the following functions from `Monomorphize.elm` to `Analysis.elm`:
- `computeCtorShapesForGraph` (lines ~390-426)
- `buildCompleteCtorShapes` (lines ~355-363)
- `buildCtorShapeFromUnion` (lines ~369-379)

`Analysis.elm` will need new imports:
- `Compiler.Monomorphize.TypeSubst as TypeSubst` (for `applySubst`)
- `Compiler.Data.Index as Index` (for `Index.toMachine`)
- `Compiler.Elm.ModuleName as ModuleName` (already imported or needed for crash message)
- `Utils.Crash` (for the crash in `computeCtorShapesForGraph`)
- `Data.EverySet as EverySet` (for `EverySet.toList`)

Update `Analysis.elm`'s module exposing to add `computeCtorShapesForGraph`.

In `Monomorphize.elm`: remove the moved functions and update the call site at line ~120 to use `Analysis.computeCtorShapesForGraph`.

### Step 4: Create `compiler/src/Compiler/Monomorphize/Prune.elm`

New module exposing `pruneUnreachableSpecs`.

#### 4a. `reachableFromMain : Mono.MonoGraph -> Set Int`

Tail-recursive BFS from `mainSpecId` over `callEdges`, returning `Set Int` of reachable SpecIds.
- If `main = Nothing` (library mode), conservatively return all specIds from `nodes`.
- Uses `Data.Set` (wraps `EverySet`).
- Worklist loop: pop specId, skip if already in `seen`, otherwise add to `seen` and push all outgoing `callEdges[specId]` onto worklist.

#### 4b. `pruneUnreachableSpecs : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph`

Takes `globalTypeEnv` so it can recompute ctorShapes. Given the `live` set from `reachableFromMain`:

1. **Filter `nodes`** — `Data.Map.filter (\specId _ -> Set.member specId live)`
2. **Filter `callEdges`** — same filter on keys
3. **Rebuild `reverseMapping`** — `Array.indexedMap (\i entry -> if Set.member i live then entry else Nothing)` to null out dead entries
4. **Rebuild `mapping`** — fold over the pruned `reverseMapping` using `Array.toIndexedList`, inserting only `Just` entries with live specIds via `Mono.toComparableSpecKey`
5. **Recompute `ctorShapes`** — call `Analysis.computeCtorShapesForGraph globalTypeEnv prunedNodes` so only types referenced by reachable nodes survive

Unchanged fields: `main`, `nextId`, `nextLambdaIndex`.

Key design decisions:
- **Do NOT renumber SpecIds** — just drop entries. `reverseMapping` stays the same length; dead entries become `Nothing`. Preserves stability for downstream passes.
- `Array.indexedMap` is available in standard Elm.

Imports needed:
- `Compiler.AST.Monomorphized as Mono`
- `Compiler.AST.TypeEnv as TypeEnv`
- `Compiler.Monomorphize.Analysis as Analysis`
- `Data.Map as Dict`
- `Data.Set as Set`
- `Array`

### Step 5: Wire pruning into `monomorphizeFromEntry`

In `compiler/src/Compiler/Monomorphize/Monomorphize.elm`:

1. Add import: `import Compiler.Monomorphize.Prune as Prune`
2. Change the tail of `monomorphizeFromEntry` (lines ~115-128):

Before:
```elm
    ctorShapes = computeCtorShapesForGraph finalState.globalTypeEnv finalState.nodes
in
Ok (Mono.MonoGraph { nodes = ..., ctorShapes = ctorShapes, ... })
```

After:
```elm
    rawGraph = Mono.MonoGraph
        { nodes = finalState.nodes
        , registry = finalState.registry
        , main = mainInfo
        , ctorShapes = Dict.empty  -- will be computed after pruning
        , nextLambdaIndex = finalState.lambdaCounter
        , callEdges = finalState.callEdges
        }
    prunedGraph = Prune.pruneUnreachableSpecs finalState.globalTypeEnv rawGraph
in
Ok prunedGraph
```

Remove the `ctorShapes` computation from `monomorphizeFromEntry` since `pruneUnreachableSpecs` handles it.

### Step 6: Update MONO_011 test logic in `design_docs/invariant-test-logic.md`

Update the MONO_011 entry (lines ~560-581):
- Remove: "Detect unreachable `SpecId`s and ensure they're either optimized away or flagged"
- Replace with: "Assert no unreachable SpecIds exist (guaranteed by MONO_022 pruning pass)"
- Update oracle: "No dangling references, no undefined globals, no unreachable specs in the registry" → strengthen to "no unreachable specs possible by construction"

### Step 7: Update MONO_005 / MONO_017 test logic in `design_docs/invariant-test-logic.md`

**MONO_005** (line ~493): Currently says "Assert there are no registry entries that are never referenced." Update to clarify that `Nothing` entries in `reverseMapping` are expected (pruned slots) and are not violations. Only `Just` entries must have corresponding nodes.

**MONO_017** (line ~629): Currently says "If node not found: violation (orphan registry entry)." Update to: skip `Nothing` entries in `reverseMapping` (they represent pruned slots). Only `Just` entries where the node is missing are violations. The existing test code already uses `Maybe.andThen identity` which handles this, but the prose should be explicit.

### Step 8: Add MONO_022 test entry to `design_docs/invariant-test-logic.md`

Add a new test block for MONO_022 after MONO_021:
- Recompute reachability from `mainSpecId` over `callEdges` (same BFS as in `Prune.elm`)
- Assert every key in `nodes` is in the reachable set
- Assert every `Just` entry in `reverseMapping` has a specId in the reachable set
- Assert every value in `registry.mapping` is in the reachable set
- Assert every key in `ctorShapes` corresponds to a type actually referenced by a reachable node

### Step 9: Tighten MONO_021 prose

Update MONO_021 (line ~160 in `invariants.csv`) to scope its check to reachable nodes only and reference MONO_022:

```
MONO_021;Monomorphization;Types;documented;After monomorphization and at MLIR codegen entry every reachable non-kernel user-defined function or closure specialization (reachable per MONO_022) has no MVar with CEcoValue in its MFunction parameter or result positions. Any remaining CEcoValue MVar is restricted to kernel-facing or metadata-only Mono nodes and unreachable template specializations are removed by MONO_022.;Compiler.AST.Monomorphized|Compiler.Monomorphize.Specialize|Compiler.Monomorphize.Prune
```

Update the MONO_021 test logic entry (lines ~672-691) to only inspect nodes whose specId is in the reachable set.

### Step 10: Build and test

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
cmake --build build --target check
```

---

## Resolved Questions

- **`Array.indexedMap`**: Available in standard Elm.
- **Library mode**: Conservatively keep everything when `main = Nothing`. Confirmed correct.
- **`callEdges` completeness**: Tracks all `MonoVarGlobal` uses (functions, ctors, enums, ports). Sufficient for SpecId reachability.
- **`ctorShapes` pruning**: Yes, prune them. Recompute from pruned nodes via `Analysis.computeCtorShapesForGraph`.
- **`reverseMapping` consumers**: All downstream passes handle `Nothing` already. MONO_017/MONO_005 test prose needs tightening to treat `Nothing` as "pruned slot" not "violation".
- **Where to put `computeCtorShapesForGraph`**: Move to `Analysis.elm` (option a). It already has `collectAllCustomTypes` and `lookupUnion`. New imports needed: `TypeSubst`, `Index`, `Utils.Crash`, `EverySet`.

## Notes

- The BFS worklist in `reachableFromMain` is tail-recursive (each iteration either skips a visited node or adds it to `seen` and recurses on `rest ++ outgoing`). Safe for large graphs since each specId visited at most once.
- `Prune.elm` takes `GlobalTypeEnv` as a parameter to enable ctorShapes recomputation without circular imports.
