# MonoGraph Fields Tracing: callEdges, specHasEffects, specValueUsed

## MonoGraph Definition
File: `/work/compiler/src/Compiler/AST/Monomorphized.elm` (lines 436-448)

MonoGraph contains three important fields:
```elm
callEdges : Array (Maybe (List Int))     -- Line 445
specHasEffects : BitSet                  -- Line 446
specValueUsed : BitSet                   -- Line 447
```

Semantics:
- **callEdges**: Array indexed by SpecId. Each entry is a list of SpecIds that this function calls. Collected during monomorphization. Used to avoid re-traversing MonoExpr trees in downstream passes.
- **specHasEffects**: BitSet of SpecIds whose node body references Debug.* kernels (binding-time effects)
- **specValueUsed**: BitSet of SpecIds whose value is referenced via MonoVarGlobal

## Production (Where They Are Created/Populated)

### Phase 1: Monomorphize.State (lines 89-91)
Intermediate state type during monomorphization:
```
callEdges : Dict Int (List Int)         -- Line 89
specHasEffects : BitSet                 -- Line 90
specValueUsed : BitSet                  -- Line 91
```
Initialized at line 268-270.

### Phase 2: Monomorphize.Monomorphize
Main monomorphization module that populates these fields.

**Key functions:**
- `processWorklist` (line 287): Main worklist loop processing specializations
  - Lines 260-280: Accessor global handling - updates specValueUsed
  - Lines 341-345: specValueUsed populated from MonoVarGlobal references
  - Lines 354-355: callEdges populated via Dict.insert
  - Lines 410-433: specHasEffects updated when effectsHere detected
  
- `nodeHasEffects` (lines 558-590): Detects if node contains Debug.* references
  - Uses Traverse.foldExpr to scan for Mono.MonoVarKernel _ "Debug" _ _
  
- `collectCallsFromNode` (lines 521-549): Collects called SpecIds
  - Uses `collectCalls` which uses `Traverse.foldExpr extractSpecId`
  - Extracts Mono.MonoVarGlobal _ specId _ references

- `assembleRawGraphFrom` (lines 184-234): Converts Dict-based state to Array-based MonoGraph
  - Lines 214-223: Converts callEdges Dict → Array
  - Lines 231-233: Copies specHasEffects and specValueUsed BitSets to MonoGraph

### Phase 2b: MonoDirect.Monomorphize (solver-directed variant)
Similar population for test-only solver path:
- `finalizeSpec` (lines 248-282): Updates callEdges, specHasEffects, specValueUsed
  - Lines 260-264: specValueUsed from neighbors
  - Lines 274-279: specHasEffects when effectsHere detected
  - Line 273: callEdges via Dict.insert
  
- `assembleRawGraph` (lines 322-365): Final graph assembly
  - Lines 346-354: callEdges Dict → Array conversion
  - Lines 362-364: Copies BitSets to MonoGraph

### State Modules
Two state modules track these as Dict/BitSet during accumulation:
- `/work/compiler/src/Compiler/Monomorphize/State.elm` (lines 89-91)
- `/work/compiler/src/Compiler/MonoDirect/State.elm` (lines 76-78)

Initialized empty in each module's initState function.

## Consumption (Where They Are Used)

### Phase 3: Monomorphize.Prune (Reachability analysis)
File: `/work/compiler/src/Compiler/Monomorphize/Prune.elm`

**Functions:**
- `pruneUnreachableSpecs` (line 84): Main pruning function
- `reachableFromMain` (line 26): Computes BitSet of reachable SpecIds
- `markReachable` (lines 54-77): DFS traversal over callEdges
  - Line 49: Uses callEdges array for DFS: `Array.get specId callEdges`
  - Line 70: Accesses neighbor list from callEdges entry
  - Builds BitSet of reachable specs starting from main

**Behavior:**
- Lines 104-115: Filters callEdges array to remove pruned entries
- Lines 174-175: Passes specHasEffects and specValueUsed through unchanged
  - Comment: "Stale bits for pruned specIds are harmless — no node exists to reference them"

### Phase 4: GlobalOpt.MonoInlineSimplify (Inlining pass)
File: `/work/compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

**Functions:**
- `optimize` (lines 52-76): Main entry point
  - Line 55: Destructures all fields including callEdges, specHasEffects, specValueUsed
  - Line 62: Builds call graph from callEdges: `buildCallGraph nodes callEdges`
  - Lines 75, 89: Passes all fields through to optimizeNodes
  
- `optimizeNodes` (lines 89-133): Node optimization
  - Lines 128-130: Passes callEdges, specHasEffects, specValueUsed through unchanged
  - Returns rebuilt MonoGraph with preserved fields

**Behavior:**
- callEdges is used to build call graph for inlining decisions
- specHasEffects and specValueUsed are preserved but not modified

### Not Yet Consumed
Files checked that DON'T consume these fields:
- Backend.elm: Destructures only nodes, main, registry, ctorShapes (line 53, 139)

## Summary Table

| Phase | Module | File | Lines | Role |
|-------|--------|------|-------|------|
| **Production** | Monomorphize.State | /work/compiler/src/Compiler/Monomorphize/State.elm | 89-91, 268-270 | Define state type, init empty |
| | Monomorphize.Monomorphize | /work/compiler/src/Compiler/Monomorphize/Monomorphize.elm | 260-433 | Populate via processWorklist |
| | MonoDirect.State | /work/compiler/src/Compiler/MonoDirect/State.elm | 76-78, 106-108 | Define state type, init empty |
| | MonoDirect.Monomorphize | /work/compiler/src/Compiler/MonoDirect/Monomorphize.elm | 248-292, 322-365 | Populate via finalizeSpec, assembleRawGraph |
| **Pass-through** | Monomorphize.Prune | /work/compiler/src/Compiler/Monomorphize/Prune.elm | 104-115, 171-176 | Use callEdges for reachability, preserve others |
| | MonoInlineSimplify | /work/compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm | 55, 62, 75, 89, 128-130 | Use callEdges for call graph, preserve others |
| **Not consumed** | Backend | /work/compiler/src/Compiler/Generate/MLIR/Backend.elm | 53, 139 | Not accessed |
