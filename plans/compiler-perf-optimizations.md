# Compiler Performance Optimizations Plan

## Overview

A set of targeted performance improvements to the Elm compiler backend, addressing profiler hotspots in monomorphization, GlobalOpt, SCC graph construction, type unification, and MLIR codegen. Items numbered to match the original design document (item 7 was dropped).

## Prerequisites

- Read `design_docs/invariants.csv` before touching any codegen or representation code
- Run `cd compiler && npx elm-test-rs --fuzz 1` after each item to verify frontend correctness
- Run `cmake --build build --target check` after items touching GlobalOpt/codegen

---

## Item 1: Remove per-call "flipped" closure in `MonoTraverse.foldExprChildren`

### Problem
`foldExprChildren` allocates a `flipped` lambda on every call to adapt `(acc, expr)` → `(expr, acc)` argument order. This is in the hottest traversal path.

### Files
- `compiler/src/Compiler/GlobalOpt/MonoTraverse.elm`

### Approach
1. Add internal `foldExprAccFirst : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc` that recursively uses `foldExprChildren` directly (no flip needed)
2. Re-express exported `foldExpr` as a thin wrapper that adapts its `(MonoExpr -> acc -> acc)` callback to acc-first **once**, then delegates to `foldExprAccFirst`
3. Rewrite `foldExprChildren` body to use acc-first callbacks directly, removing the `flipped` let-binding
4. Add acc-first variants: `foldDefAccFirst`, `foldDeciderAccFirst`, `foldChoiceAccFirst`
5. Keep existing `foldDef`, `foldDecider`, `foldChoice` for external callers (they call through `foldExpr` which uses the new path)

### Risks
- External callers of `foldExprChildren` directly (if any) will see the parameter order stay the same (acc-first), so no API break
- Must verify no other module calls `foldDef`/`foldDecider` with expr-first order

### Verification
- `npx elm-test-rs --fuzz 1` (frontend tests)
- `cmake --build build --target check` (E2E)

---

## Item 2: Reduce `toComparableSpecKey` cost in registry

### Problem
`SpecializationRegistry.mapping` uses `Dict (List String) (List String) SpecId` keyed by string-serialized spec keys via `toComparableSpecKey`. This allocates intermediate string lists on every lookup — a major cost in monomorphization.

### Files
- `compiler/src/Compiler/AST/Monomorphized.elm` (type alias changes)
- `compiler/src/Compiler/Monomorphize/Registry.elm` (getOrCreateSpecId, emptyRegistry)

### Constraint (Q1 resolved)
`Data.Map` wraps Elm's core `Dict` and requires a `k -> comparable` conversion function on every `get`/`insert`/`member` call. There is **no way** to use a custom comparator — you must produce a `comparable` (e.g., `List String`). So `toComparableSpecKey` cannot be eliminated entirely from the Dict path.

### Revised Approach
Since we cannot avoid a comparable key for `Data.Map`, the optimization must focus on **reducing how often `toComparableSpecKey` is called**:

1. **Memoize the comparable key per specialization**: When constructing a `SpecKey`, eagerly compute and store its comparable form so repeated lookups don't recompute it. Define:
   ```elm
   type alias MemoizedSpecKey =
       { key : SpecKey
       , comparable : List String
       }
   ```
   Compute `comparable` once at `SpecKey` construction time; use `comparable` for all Dict ops.

2. **Change `mapping` to `Dict (List String) SpecKey SpecId`**: Store the real `SpecKey` as the value-side key (`k`) so consumers can recover it without round-tripping through the comparable form. Use the pre-computed comparable as the `c` parameter.

3. **Optimize `toComparableSpecKey` itself**: Profile `toComparableMonoTypeHelper` — consider using a more compact encoding (e.g., single `String` with delimiters instead of `List String`) to reduce list allocation. A single `String.concat` may be cheaper than building nested `List String`.

4. Keep `toComparableSpecKey` for non-hot paths (debug printing, serialization).

### Risks
- Memoization adds a small per-SpecKey overhead for keys that are only looked up once
- Changing the comparable encoding (e.g., to single String) requires verifying no collisions
- Must audit all callers of `registry.mapping`

### Verification
- Frontend + E2E tests
- Compare monomorphization time on a large module before/after

---

## Item 3: Arrays for `SpecId`-indexed data

### Problem
`reverseMapping` is a `Dict Int (Global, MonoType, Maybe LambdaId)` keyed by dense `SpecId`s. Dict overhead is unnecessary for dense integer indices.

### Files
- `compiler/src/Compiler/AST/Monomorphized.elm`
- `compiler/src/Compiler/Monomorphize/Registry.elm`
- Callers of `registry.reverseMapping` (e.g. `MonoGlobalOptimize.specHome`)

### Approach
1. Change `reverseMapping` to `Array (Maybe (Global, MonoType, Maybe LambdaId))`
2. Initialize with `Array.empty`, grow lazily in `getOrCreateSpecId` using `Array.append` + `Array.repeat` when specId >= length
3. Update `updateRegistryType` and `lookupSpecKey` to use `Array.get`
4. Update all callers (grep for `reverseMapping`)
5. Where full-graph passes iterate `Dict.foldl` over `mono.nodes`, consider switching to `nodesToArray` + `Array.foldl`

### Risks
- Array growth strategy: appending `Array.repeat (specId + 1 - len) Nothing` on each overflow. Since specIds are sequential, this should only grow by 1 each time (no wasted space)
- Must handle `Array.get` returning `Nothing` for both out-of-bounds and unset entries

### Verification
- Frontend + E2E tests

---

## Item 4: Less allocation-heavy SCC adjacency construction

### Problem
`Graph.buildGraphs` does `Array.set` per edge in inner loops, causing persistent-array copy overhead that shows up as `Array.setHelp` in profiles. Same pattern in `MonoInlineSimplify.buildCallGraph`.

### Files
- `compiler/src/Compiler/Graph.elm`
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

### Approach
1. In `Graph.buildGraphs`: accumulate edges in `Dict Int (List Int)` for both forward and reverse adjacency, then convert to `Array (List Int)` in one pass via `Dict.foldl` into `Array.repeat n [] |> set per vertex`
2. This trades O(E) persistent-array updates for O(V) updates (one per vertex)
3. Optionally add a helper `Graph.fromEdges : Int -> List (Int, List Int) -> IntGraph` for reuse
4. Refactor `MonoInlineSimplify.buildCallGraph` to use the same batch construction

### Scope (Q2 resolved)
Only two sites construct `IntGraph` or call `stronglyConnCompInt`:
1. **`Compiler.Graph`** — internal definition + `fromAdjacency`
2. **`MonoInlineSimplify.buildCallGraph`** — builds its own `{ fwd, trans, selfLoops, size }` record and calls `Graph.stronglyConnCompInt`

No other modules construct `IntGraph`. So changes to `IntGraph` construction only require updating:
- `Compiler.Graph.stronglyConnCompInt` / `fromAdjacency` (internal)
- `MonoInlineSimplify.buildCallGraph`'s `buildResult` record literal and its `stronglyConnCompInt` call site

Everything else uses the generic `stronglyConnComp` / `stronglyConnCompR` APIs and is insulated.

### Risks
- Dict overhead for edge accumulation — but Dict inserts are O(log V) vs O(copy) for persistent Array.set, so net win for large graphs
- Must preserve self-loop detection (BitSet) behavior

### Verification
- Frontend + E2E tests
- SCC results must be identical (topological order may differ but components must match)

---

## Item 5: Thin out GlobalOpt traversals

### Problem
`Staging.GraphBuilder.buildStagingGraph` and `ProducerInfo.computeProducerInfo` each walk the entire `MonoGraph`. Many subtrees contain only non-function values and don't need staging analysis.

### Files
- `compiler/src/Compiler/GlobalOpt/Staging/GraphBuilder.elm`
- `compiler/src/Compiler/GlobalOpt/Staging/ProducerInfo.elm`
- `compiler/src/Compiler/GlobalOpt/CallInfo.elm`

### Approach

**Phase A: Early exit on non-function subtrees (lower risk)**
1. In `buildStagingGraphExpr`, for `MonoList`, `MonoTupleCreate`, `MonoRecordCreate`, and constructor args: check `Mono.isFunctionType (Mono.typeOf e)` before recursing into elements
2. Skip recursion entirely for elements that can't contain function values

**Phase B: Fused pass (higher risk, optional)**
1. Combine `computeProducerInfo` + `buildStagingGraph` into a single traversal
2. Thread a combined `BuildState` with both `ProducerInfo` and `StagingGraph`
3. Single `MonoTraverse.traverseExpr` per node

### Status of Q3 (resolved: unknown, needs measurement)
There is no existing pass that reports the ratio of function-typed vs data-typed `MonoExpr` nodes. Structurally, UI-heavy Elm code likely has large non-function subtrees (records, lists, JSON), while core libs have more function values. **Recommendation: add a cheap analysis pass** that counts total `MonoExpr` nodes vs `isFunctionType` nodes, run on representative builds to decide if Phase A is worthwhile before implementing.

### Design Decision (Q4 resolved)
Phase B (fusing ProducerInfo + StagingGraph) **is worth it**, with a pragmatic approach:
- `ProducerInfo` and `StagingGraph` are already part of one conceptual "staging analysis" phase; neither is reused elsewhere
- The fused builder eliminates one full `MonoGraph` traversal, reducing GC and allocation pressure
- **Implementation**: Add an internal fused function `buildProducerInfoAndStagingGraph : MonoGraph -> (ProducerInfo, StagingGraph)` that simultaneously updates both accumulators in a single traversal
- **Decoupling preserved**: Keep `ProducerInfo` as a public data type; keep old functions available for tests/future reuse
- **Call site**: Change `Staging.analyzeAndSolveStaging` to call the fused function instead of the two separate passes

### Risks
- Must ensure `isFunctionType` check is reliable — if a function value is nested inside a non-function container (e.g., record with a function field), we must still recurse. Specifically: a `MonoRecord` with a function-typed field must still be descended into, so the check must be on the *element* type, not the container type.
- Phase B: coupling risk, harder to test independently
- Phase A may have negligible benefit if most subtrees are function-typed — measure first

### Verification
- E2E tests (staging correctness is critical)
- Specific test cases with function values in containers
- Run the measurement pass before and after to confirm skip rate

---

## Item 6: Optimize type unification and substitution in monomorphization

### Problem
`TypeSubst.unify` and `applySubst` recursively walk types without caching. Common kernel/library functions are unified against the same declared type many times with different concrete types.

### Files
- `compiler/src/Compiler/Monomorphize/TypeSubst.elm`
- `compiler/src/Compiler/PostSolve.elm`
- `compiler/src/Compiler/Monomorphize/Specialize.elm`

### Approach

**Step 1: Cache unification results for common functions**
- Add a unification cache keyed by `(Global, MonoType)` → `Substitution`
- Thread cache through `Specialize.specializeNode` or store in `MonoState`
- Look up before calling `TypeSubst.unify`; store result after

**Step 2: Per-call memo table for `applySubst`**
- Add `applySubstWithCache : Substitution -> LocalCache -> Can.Type -> (MonoType, LocalCache)`
- Thread through `specializeExpr` so repeated identical types are computed once

**Step 3: Pre-normalize canonical types**
- Ensure `Can.Type` entering monomorphization has aliases expanded and record fields sorted
- Reduces work in `unifyHelp` (fewer `Dict.toList` and length comparisons)

### Measurement Strategy (Q5: needs instrumentation)
The cache hit rate depends on the workload and can't be determined statically. **Add counters to `MonoState`** before implementing caching:
1. Add `unifyCalls : Int` and `unifyKeySet : EverySet (Global, MonoType)` to `MonoState`
2. Wrap the top-level unification entry point (in `Monomorphize.processWorklist` where `TypeSubst.unifyHelp`/`applySubst` is called against a definition's annotated type) to increment the counter and track distinct keys
3. At the end of monomorphization, dump `unifyCalls` and `EverySet.size unifyKeySet`
4. Compute the ratio on representative builds to decide if caching pays off

### Cache Threading (Q6 resolved: feasible, no major refactor needed)
Two viable approaches, **neither requires changing `specializeExpr`'s signature**:

**Option 1 (recommended): Cache inside `Substitution` itself**
- Change `Substitution` from a bare `Dict` to a record:
  ```elm
  type alias Substitution =
      { types : Dict String Name MonoType
      , unifyCache : Dict (Can.Type, MonoType) SubstitutionFragment
      }
  ```
- Update `TypeSubst.unifyHelp`/`applySubst` to check/populate the cache
- Because `Substitution` is already threaded everywhere, no signature changes propagate

**Option 2: Cache at the WorkItem layer in `MonoState`**
- Add `unifyCache : Dict (Global, MonoType) Substitution` to `MonoState`
- Check cache in `processWorklist` before calling `specializeNode`; store result after
- Also requires no changes to `specializeExpr`

### Risks
- Cache invalidation: canonical types are stable, so this is safe
- Memory pressure from stored substitutions — scope cache to current compilation unit
- Step 3 (pre-normalize types) may require PostSolve changes affecting other passes
- Must instrument (Q5) before committing to caching implementation

### Verification
- Frontend + E2E tests
- Compare monomorphization time before/after

---

## Item 8: Arrays/BitSet in `MonoState`

### Problem
`MonoState.nodes` and `callEdges` are `Dict Int` keyed by dense SpecIds. `inProgress` is `EverySet Int` (a Set). All have unnecessary overhead for dense integer keys.

### Files
- `compiler/src/Compiler/Monomorphize/State.elm`
- `compiler/src/Compiler/AST/Monomorphized.elm`
- `compiler/src/Compiler/Data/BitSet.elm`

### Approach

**Step 1: Array mirror for `nodes` (incremental approach)**
- Add `nodeArray : Array (Maybe MonoNode)` alongside existing `nodes` Dict in `MonoState`
- Update both on insert; use array for iteration-heavy internal loops (e.g., building `callEdges`)
- Keep the Dict as the authoritative representation — `MonoGraph` exposes it and many consumers expect it (Monomorphize, Analysis, GlobalOpt, backend)
- `nodesToArray` already exists in `Monomorphized.elm` and is used by the MLIR backend; this mirrors that pattern into `MonoState` for hot loops during monomorphization itself

**Step 2: Array for `callEdges`**
- Change `callEdges : Dict Int (List Int)` to `Array (List Int)`
- Grow lazily like `reverseMapping` in Item 3

**Step 3: BitSet for `inProgress`**
- Replace `EverySet Int Int` with `BitSet`
- Initialize with estimated max size from registry.nextId
- Use `BitSet.insert`/`BitSet.member` instead of Set operations

### Design Decision (Q7 resolved)
Full replacement of `nodes` Dict with Array is possible in principle but invasive — it touches Monomorphization, Analysis (`collectAllCustomTypes`), type layout computation (`computeCtorShapesForGraph`), GlobalOpt, and backend, all of which currently expect Dicts. The **safer incremental approach** is to supplement with an array mirror in `MonoState` for internal hot loops, without changing the published `MonoGraph` API. A full migration can be considered later if profiling shows the Dict overhead in downstream passes is significant.

### Risks
- Dual storage (Dict + Array) increases memory — acceptable since the array stores `Maybe` references (not copies) and is only in `MonoState` (not persisted to `MonoGraph`)
- BitSet may need resizing if specId space grows beyond initial estimate

### Verification
- Frontend + E2E tests

---

## Item 9: Array-based `CallEnv` in GlobalOpt

### Problem
`CallEnv` uses `Dict String Name` for `varCallModel` and `varSourceArity`. These Dicts are updated per-expression during call annotation, using string keys.

### Files
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Approach
1. At the start of each `MonoNode` processing, collect all variable names (params, let-bindings, destructs) into a `VarIndexEnv : Dict String Name Int` mapping names to dense indices 0..N-1
2. Replace `CallEnv` Dicts with fixed-size arrays:
   ```
   { varCallModel : Array CallModel
   , varSourceArity : Array Int
   , varIndex : VarIndexEnv
   }
   ```
3. Initialize arrays with `Array.repeat size defaultValue`
4. Update/lookup via `Dict.get identity name env.varIndex` → `Array.get idx` / `Array.set idx`

### Scope Clarification (Q8: needs measurement, but scope is narrow)
`CallEnv` only stores entries for **let-bound functions** whose call model/arity can be inferred (via `annotateDefCalls`). Parameters are handled separately through `sourceArityForExpr` and global node inspection. So the Dict size is "number of let-bound functions per node", not all variables in scope.

**Measurement strategy**: Add counters to the annotate pass:
1. Track `maxEnvSize` and histogram buckets (`size1_4`, `size5_16`, `size17_64`, `size65plus`) during `annotateNodeCalls`
2. Dump stats at the end of `annotateCallStaging`
3. If 95%+ of functions have ≤8 entries, a small fixed-size array is attractive; if many have dozens, consider a hybrid (small array + spill map)

### Risks
- Must collect ALL let-bound function names before starting traversal — any missed name causes lookup failure
- Default values for uninitialized array slots must be correct (e.g., `FlattenedExternal` for call model)
- If typical sizes are very small (< 5), the optimization may not be worth the added complexity

### Verification
- E2E tests (GlobalOpt correctness)

---

## Item 10: Fix `mkCaseRegionFromDecider` crash + Stage-5 benchmark

### Problem
`mkCaseRegionFromDecider` crashes with "non-yield terminator with empty resultVar" when `generateLeafWithJumps` passes through a terminated branch that doesn't end with `eco.yield`.

### Files
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`
- Test harness (new benchmark)

### Approach

**Step 1: Fix `generateLeafWithJumps`**
- Only short-circuit for terminated branches if the last op IS `eco.yield` (check via `isValidCaseTerminator`)
- Otherwise, wrap with `eco.yield` as normal (add coercion + yield ops)
- Add `lastOpOf` helper to inspect the final op

**Step 2: Defensive fallback in `mkCaseRegionFromDecider`**
- Replace the crash for `resultVar == ""` with a fallback that emits a dummy `eco.yield` of an undefined value
- This prevents hard crashes during development while invariants are being tightened
- Include a `Debug.log` warning so the fallback is visible during testing

**Step 3: Stage-5 benchmark harness**
- Create a script/test that runs the compiler through MLIR generation on heavy modules
- Enable profiling to identify codegen hotspots
- Include in local perf workflow

### Root Cause Analysis (Q9 resolved)
The only expressions that produce `ExprResult` with `isTerminated = True`, `resultVar == ""`, and a non-`eco.yield` last op are **control-flow-only** expressions:
- **`eco.return`** at function/joinpoint exits (from `TailRec.buildTailLoop`)
- **crash/unreachable** code paths

Case alternatives in Elm are expressions and must yield a value. If `generateExpr` produces `eco.return` inside a decider alternative, that's a **deeper codegen bug** — function returns and joinpoints are not valid inside `eco.case` alternatives per the op definitions.

Therefore the fix in `generateLeafWithJumps` is narrowly scoped: ensure that when `branchRes.isTerminated` is true, we only pass through if the last op is actually `eco.yield`. Any other terminator (e.g., `eco.return` leaking into a case alternative) should be treated as a bug — the defensive fallback in Step 2 catches this gracefully during development, but should be investigated and fixed at the source.

### Design Decision (Q10 resolved: always crash)
**Keep the crash in both debug and release builds.** Rationale:
- This is a hard compiler bug: emitting an `eco.case` alternative whose last op doesn't produce a value results in semantically wrong IR
- A "dummy yield" would produce silently miscompiled code — worse than a crash
- The existing crash message ("non-yield terminator with empty resultVar") already helped find a real bug; suppressing it would make future bugs harder to diagnose
- If a developer build needs to continue past the crash for investigation, an explicit `--unsafe-continue-on-bug` flag could be added later, but this should not be the default

**Step 2 revised**: Instead of a dummy yield fallback, improve the crash message to include the offending op name, the expression context, and the SpecId, making diagnosis faster. No silent fallback.

### Risks
- Must verify the fix in Step 1 (`generateLeafWithJumps`) eliminates all known crash scenarios
- Must verify the fix doesn't break existing case lowering for tail-recursive functions
- If `eco.return` is legitimately appearing inside case alternatives, there's a deeper issue in how tail-recursive functions are lowered that needs separate investigation

### Verification
- E2E tests (especially test cases with complex case expressions)
- Verify the specific crash scenario is resolved
- Run the new benchmark

---

## Suggested Implementation Order

1. **Item 1** (MonoTraverse flip) — Self-contained, low risk, immediate benefit
2. **Item 3** (Array for reverseMapping) — Simple mechanical change
3. **Item 8** (Arrays/BitSet in MonoState) — Builds on Item 3 patterns, incremental (array mirror, not full replacement)
4. **Item 10** (mkCaseRegionFromDecider fix) — Bug fix, independent of perf items, root cause understood, always-crash decision made
5. **Item 2** (Memoize/optimize toComparableSpecKey) — Memoize comparable form or optimize to single-String encoding
6. **Item 4** (SCC adjacency) — Moderate complexity, only 2 sites to update (Graph.elm + MonoInlineSimplify)
7. **Item 9** (Array-based CallEnv) — Moderate, localized to GlobalOpt. Instrument first to confirm sizes warrant arrays.
8. **Item 5** (Thin GlobalOpt traversals) — Phase A: measure first (counting pass), then skip non-function subtrees. Phase B: fused ProducerInfo+StagingGraph builder (approved).
9. **Item 6** (Type unification caching) — Instrument hit rate first, then cache inside Substitution record

## Questions Summary

All questions are now resolved. Items requiring pre-implementation measurement are noted inline.

| # | Question | Resolution |
|---|----------|------------|
| Q1 | `SpecKey` in `Data.Map`? | **No.** Must keep `toComparableSpecKey`; optimize via memoization or compact encoding. |
| Q2 | Other `IntGraph` sites? | **Only 2:** `Graph.elm` (internal) + `MonoInlineSimplify.buildCallGraph`. Safe to change. |
| Q3 | Non-function node fraction? | **Unknown — measure first.** Add counting pass before committing to Item 5 Phase A. |
| Q4 | Fuse ProducerInfo+StagingGraph? | **Yes.** Add internal fused builder; keep old functions for tests. |
| Q5 | Unification cache hit rate? | **Unknown — instrument first.** Add counters to `MonoState` before implementing caching. |
| Q6 | Cache threading feasible? | **Yes.** Hide cache inside `Substitution` record (Option 1) — no signature changes needed. |
| Q7 | Replace `nodes` Dict with Array? | **Too invasive.** Use array mirror in `MonoState` for hot loops; keep Dict as authority. |
| Q8 | Typical `CallEnv` size? | **Unknown — instrument first.** Add histogram counters to `annotateNodeCalls`. |
| Q9 | Non-yield terminated branches? | **Only `eco.return` and crash paths.** If in case alternatives, it's a deeper codegen bug. |
| Q10 | Dummy yield: debug or always? | **Always crash.** Silent fallback would mask bugs and produce miscompiled code. Improve crash message instead. |
