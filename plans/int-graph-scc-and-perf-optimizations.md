# Int-Graph SCC & Performance Optimizations

## Summary

Nine related performance improvements targeting SCC computation, Dict churn,
BitSet initialization, MLIR codegen iteration, monomorphization environment
overhead, GC boundaries, and traversal deduplication.

---

## Step-by-step Plan

### Step 4 (implement first): Lazy BitSet initialization (`emptyWithSize`)

**File:** `compiler/src/Compiler/Data/BitSet.elm`

1. Add `emptyWithSize : Int -> BitSet` that sets `size` but uses `Array.empty`
   for `words` (no pre-allocation).
2. Add internal `ensureWord : Int -> BitSet -> BitSet` that grows the words
   array on demand when `insert` or `remove` targets a word beyond current
   capacity.
3. Update `insert` and `remove` to call `ensureWord` before `Array.get`.
4. `member` already handles missing words correctly (`Array.get → Nothing → False`).
   No change needed.
5. Export `emptyWithSize` from the module.
6. Do NOT update `setWord` or `orWord` — they can continue to assume
   pre-allocated words.

**File:** `compiler/src/Compiler/Graph.elm`

7. Replace `BitSet.fromSize n` with `BitSet.emptyWithSize n` in:
   - `reversePostOrder` (line 266) — visited set
   - `kosaraju` (line 225) — visited set
8. Keep `BitSet.fromSize n` in `buildGraphs` (line 182) for `selfLoops`,
   since `setWord` is used there and assumes full pre-allocation.

**Risk:** Low.

**Test:** `cmake --build build --target check`

---

### Step 3 (implement second): Cut list churn in SCC DFS helpers

**File:** `compiler/src/Compiler/Graph.elm`

1. **`rpoHelp`** (line 275): Replace `List.map Enter neighbors` followed by
   `childWork ++ (Exit v :: rest)` with `List.foldl` that conses `Enter n`
   items onto `(Exit v :: rest)`.

   **Note on order:** `List.foldl` reverses neighbor visit order relative to
   `List.map + ++`. This changes DFS visit order and therefore the
   reverse-post-order, which changes SCC discovery order. However:
   - SCC *grouping* (which nodes are in which component) is unchanged.
   - No downstream consumer depends on intra-SCC element ordering or
     inter-SCC list ordering (verified — see Resolved Q1).
   - If extra caution desired, use `List.foldr` to preserve original order
     (but this doesn't save allocation). Recommendation: use `List.foldl`
     and accept the order change.

2. **`collectHelp`** (line 308): Replace `neighbors ++ rest` with
   `List.foldl (\n s -> n :: s) rest neighbors`. Same order note applies;
   same conclusion: safe.

**Risk:** Low. SCC correctness is order-independent; no consumer relies on
element ordering within SCCs.

**Test:** `cmake --build build --target check`

---

### Step 1 (implement third): Int-specialized SCC API in `Compiler.Graph`

**File:** `compiler/src/Compiler/Graph.elm`

1. Add `IntGraph` type alias:
   ```elm
   type alias IntGraph =
       { fwd : Array (List Int)
       , trans : Array (List Int)
       , selfLoops : BitSet
       , size : Int
       }
   ```
2. Add `stronglyConnCompInt : IntGraph -> List (SCC Int)` that reuses
   `reversePostOrder` and `collectComponent` but returns `SCC Int` directly
   (no triple indirection, no `binarySearch`).
3. Add `fromAdjacency` convenience constructor for `IntGraph`.
4. Update module exposing list.

**Key difference from `kosaraju`:** Vertices *are* their indices. No
`Array.get` into a triples array to map back to `(node, key, deps)`.

**Risk:** Low. Additive change, no existing code modified.

**Test:** `cmake --build build --target check`

---

### Step 2 (implement fourth): Use `stronglyConnCompInt` in `MonoInlineSimplify.buildCallGraph`

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` (lines 158–217)

1. Replace the current `buildCallGraph` which builds `(specId, specId, neighbors)`
   triples and calls `Graph.stronglyConnComp`.
2. New implementation:
   - Build a dense `SpecId → index` mapping via `Dict`.
   - Build `fwd`, `trans` (Array), and `selfLoops` (BitSet) directly from
     `callEdges`.
   - Call `Graph.stronglyConnCompInt`.
   - Map indices back to `SpecId` via an `Array SpecId`.
3. Rest of function (marking recursive nodes, MonoCycle handling) unchanged.

**Risk:** Medium. SpecIds from `callEdges` must be a subset of SpecIds in
`nodes` (they are — built from the same monomorphization worklist).

**Test:** `cmake --build build --target check`

---

### Step 5 (independent): Remove `typeIds` dict from `TypeTableAccum`

**File:** `compiler/src/Compiler/Generate/MLIR/TypeTable.elm`

1. The `typeIds` field (line 118) is populated from `ctx.typeRegistry.typeIds`
   (line 147) and used read-only via `lookupTypeId` (line 298–303).
2. Change `lookupTypeId` to take `typeIds : Dict.Dict (List String) Int` as
   an explicit parameter instead of reading from the accumulator.
3. Remove `typeIds` from `TypeTableAccum`.
4. Update `emptyAccum` construction (remove `typeIds` field).
5. Update all call sites of `lookupTypeId` — these are all within
   `TypeTable.elm`:
   - `addListType` (1 call)
   - `addTupleType` (1 call in a fold)
   - `addRecordType` (1 call in a fold)
   - `addCustomType` → `addCtorInfo` (1 call in a fold)
   - `addFunctionType` (2 calls: arg types + result type)
6. Thread the `typeIds` dict as a parameter through these helpers, or capture
   it as a closure variable in `generateTypeTable` where the fold is defined.

**Preferred approach:** Capture `typeIds` as a let-binding in `generateTypeTable`
(it's `ctx.typeRegistry.typeIds`), then pass it as a parameter to `processType`
and its helpers. This avoids adding it to every helper's signature — just the
ones that call `lookupTypeId`.

**Risk:** Low. All changes confined to `TypeTable.elm`. Mechanical refactor.

**Test:** `TEST_FILTER=codegen cmake --build build --target check`

---

### Step 6 (independent): `nodesToArray` for MLIR codegen iteration

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

1. Add `nodesToArray : MonoGraph -> Array (Maybe MonoNode)` that builds a
   dense array indexed by SpecId.
2. Export it.

**File:** `compiler/src/Compiler/Generate/MLIR/Backend.elm` (lines 61–71)

3. Replace `EveryDict.foldl compare` over `nodes` with `Array.foldl` over
   `nodesToArray`, tracking the current index as the SpecId.

**Density consideration:** SpecIds come from a monotonic counter
(`SpecializationRegistry.nextId`). No explicit compaction after pruning, but
in practice `maxId` should be ~1–2× `Dict.size nodes`. Add a density guard:
```elm
if maxId <= 4 * nodeCount then
    -- use array path
else
    -- fall back to Dict.foldl
```
This prevents pathological memory waste if pruning ever creates large gaps.

**Risk:** Medium. Must correctly track `specId` as array index.

**Test:** `TEST_FILTER=codegen cmake --build build --target check`

---

### Step 8 (independent): Split GlobalOpt into two Task boundaries

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

1. Remove the `MonoInlineSimplify.optimize` call from `globalOptimize`
   (line 99–100).
2. `globalOptimize` now assumes inline/simplify has already been applied.
   Update doc comment to reflect this.

**File:** `compiler/src/Builder/Generate.elm` (lines 621–629)

3. Add import: `import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify`
4. Split the single `globalOptimize` Task into two Task boundaries:
   ```
   |> Task.andThen (\monoGraph0 ->
       -- GC boundary
       Task.io (IO.writeLn IO.stderr "Inline + simplify started...")
           |> Task.andThen (\_ ->
               let (simplifiedGraph, _) = MonoInlineSimplify.optimize monoGraph0
               in Task.io (IO.writeLn IO.stderr "Inline + simplify done.")
                   |> Task.map (\_ -> simplifiedGraph)
           )
   )
   |> Task.andThen (\simplifiedGraph ->
       -- GC boundary
       Task.io (IO.writeLn IO.stderr "Global optimization started...")
           |> Task.map (\_ -> MonoGlobalOptimize.globalOptimize simplifiedGraph)
   )
   ```

**Only caller:** `Builder/Generate.elm`. No tests or other modules call
`globalOptimize` directly (verified by search).

**Risk:** Low.

**Test:** Full E2E. Verify log output shows separate messages.

---

### Step 9 (independent): Document traversal reuse pattern

No code changes. Add a comment in `Monomorphized.elm` near `callEdges`:
```elm
, callEdges : Dict Int Int (List Int)
  -- ^ Call edges collected during monomorphization. Reuse this in downstream
  -- passes (e.g. MonoInlineSimplify) instead of re-traversing MonoExpr trees.
```

**Risk:** None.

---

### Step 7 (implement last): Layered `VarEnv` for monomorphization

**File:** `compiler/src/Compiler/Monomorphize/State.elm`

1. Add `VarEnv` type with frame stack:
   ```elm
   type VarEnv = VarEnv { frames : List (Dict String Name MonoType) }
   ```
2. Add operations:
   - `emptyVarEnv` — single empty frame
   - `lookupVar : Name -> VarEnv -> Maybe MonoType` — walks frames top-down
   - `insertVar : Name -> MonoType -> VarEnv -> VarEnv` — inserts into top frame
   - `pushFrame : VarEnv -> VarEnv` — adds empty frame on top
   - `popFrame : VarEnv -> VarEnv` — removes top frame
   - `withFreshScope : VarEnv -> VarEnv` — replaces all frames with single
     empty frame (for new function specialization, equivalent to current
     `varTypes = Dict.empty`)
3. Replace `varTypes : VarTypes` in `MonoState` with `varEnv : VarEnv`.

**File:** `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

4. Update `varTypes = Dict.empty` → `varEnv = State.emptyVarEnv` at
   specialization entry points (line ~214). These are "fresh root scope"
   sites → use `emptyVarEnv` (not `pushFrame`).

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

5. Classify each `varTypes` usage (~30+ sites):
   - **Fresh scope** (e.g., `varTypes = Dict.empty` at function entry):
     → `varEnv = State.withFreshScope state.varEnv` or `State.emptyVarEnv`
   - **Extend scope** (e.g., `Dict.insert identity name type state.varTypes`
     for let/lambda bindings): → `State.insertVar name type state.varEnv`
   - **Lookup** (e.g., `Dict.get identity name state.varTypes`):
     → `State.lookupVar name state.varEnv`
   - **Replace scope with bulk bindings** (e.g., `specializeLambda` building
     `newVarTypes` then `{ state | varTypes = newVarTypes }`):
     → `pushFrame` + bulk `insertVar` for each param

6. `specializePath` and `specializeDestructor` take `varTypes` as an explicit
   `Dict` parameter. Two options:
   - **(a)** Change them to take `VarEnv` and use `lookupVar`.
   - **(b)** Convert `VarEnv` to a flat `Dict` at the call boundary via a
     `toDict` helper, keeping the functions unchanged.
   - **Recommendation:** Option (a) for consistency. These functions only
     call `Dict.get identity name varTypes`, which maps directly to
     `lookupVar`.

7. Wrap body processing with `pushFrame`/`popFrame` at scope boundaries
   within a single specialization (let bindings, lambda bodies, case arms).

**Risk:** High. Most invasive change. Must:
- Correctly classify all ~30+ call sites.
- Ensure `withFreshScope` is used at function specialization boundaries
  (not `pushFrame`, which would leak outer bindings).
- Verify `specializeDestructor` / `specializePath` work with layered lookup.
- Thread carefully through `localMulti` specialization.

**Test:** `cmake --build build --target full` (forces full compiler rebuild).

---

## Implementation Order (final)

| Order | Step | Files Changed | Risk | Independent? |
|-------|------|--------------|------|-------------|
| 1 | Step 4 | BitSet.elm, Graph.elm | Low | Yes |
| 2 | Step 3 | Graph.elm | Low | After Step 4 |
| 3 | Step 1 | Graph.elm | Low | After Step 3 |
| 4 | Step 2 | MonoInlineSimplify.elm | Medium | After Step 1 |
| 5 | Step 5 | TypeTable.elm | Low | Yes |
| 6 | Step 6 | Monomorphized.elm, Backend.elm | Medium | Yes |
| 7 | Step 8 | MonoGlobalOptimize.elm, Generate.elm | Low | Yes |
| 8 | Step 9 | Monomorphized.elm | None | Yes |
| 9 | Step 7 | State.elm, Specialize.elm, Monomorphize.elm | High | Yes |

Steps 5–9 are all independent of each other and of Steps 1–4.
Run full E2E (`cmake --build build --target check`) after each step.
Run `--target full` after Step 7.

---

## Resolved Questions

### Q1: DFS traversal order (Step 3) ✅ RESOLVED

**Answer:** No semantic code depends on intra-SCC element ordering or SCC list
order. The two main SCC consumers are:
- **Canonicalization** (`canonicalizeValues` → `detectCycles`): only classifies
  `Declare` vs `DeclareRec`. Takes `d :: ds` from SCC but doesn't care about
  order within the component.
- **MonoInlineSimplify** (`buildCallGraph`): only marks specIds as recursive
  if they're in a `CyclicSCC`. Order irrelevant.

**Decision:** Use `List.foldl` (reverses neighbor order). Accept the order
change. SCC grouping is preserved.

### Q2: `emptyWithSize` in `buildGraphs` ✅ RESOLVED

**Answer:** Keep `fromSize n` in `buildGraphs` for `selfLoops` — it uses
`setWord` which assumes pre-allocated words. Only use `emptyWithSize` for
visited sets in `reversePostOrder` and `kosaraju`.

**Decision:** Do NOT update `setWord`/`orWord` for lazy growth.

### Q3: SpecId density (Step 6) ✅ RESOLVED

**Answer:** SpecIds come from `SpecializationRegistry.nextId`, monotonically
incremented. No explicit compaction after pruning, but IDs are demand-driven
(only created when specialization is needed), so `maxId` ≈ 1–2× `nodeCount`
in practice.

**Decision:** Add a density guard (`maxId <= 4 * nodeCount`) to fall back to
Dict iteration if pathologically sparse.

### Q4: VarEnv scope semantics (Step 7) ✅ RESOLVED

**Answer:** Two distinct patterns exist:
1. **Fresh function specialization** → `varTypes = Dict.empty` (complete reset).
   Use `withFreshScope` or `emptyVarEnv`.
2. **Nested scope within a function** (lambda, let, case) → extend existing
   bindings. Use `pushFrame`/`popFrame` + `insertVar`.

**Decision:** Provide both `withFreshScope` (replaces all frames with single
empty frame) and `pushFrame`/`popFrame`. Audit each call site to classify
which pattern applies.

### Q5: `typeIds` removal threading (Step 5) ✅ RESOLVED

**Answer:** All `lookupTypeId` calls are within `TypeTable.elm` (6 call sites
across 5 helper functions). The `typeIds` dict is initialized from
`ctx.typeRegistry.typeIds` and never mutated in the accumulator.

**Decision:** Capture `typeIds` as a let-binding in `generateTypeTable` and
thread as parameter to helpers that call `lookupTypeId`. Fully contained,
mechanical change.

### Q6: Other `globalOptimize` callers (Step 8) ✅ RESOLVED

**Answer:** Only `Builder/Generate.elm` calls `globalOptimize`. No tests or
other modules call it directly. Safe to unbundle `MonoInlineSimplify`.

### Q7: Implementation ordering (Steps 1–4) ✅ RESOLVED

**Answer:** Order 4 → 3 → 1 → 2 confirmed as sensible. Each step is small
and independently testable.

---

## Remaining Open Issues

None. All questions resolved. Ready for implementation.
