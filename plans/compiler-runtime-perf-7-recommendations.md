# Compiler Runtime Performance: 7 Recommendations Implementation Plan

## Overview

This plan implements 6 active performance recommendations targeting the compiler's runtime performance and memory overhead (Rec 3 is confirmed already handled by the Registry). The primary bottlenecks are: GC pressure from unnecessary allocations (72.5% GC time), hot Dict/List operations, and curried call overhead.

**Resolved questions:**
- **Q1.1 RESOLVED:** `==` is structural equality in the self-hosted compiler. All change-tracking must use explicit `Bool` changed flags, not equality comparison.
- **Q3.1 RESOLVED:** The Registry ensures each `(Global, MonoType, Maybe LambdaId)` tuple maps to a single SpecId. Bodies are specialized at most once. **Rec 3 is a no-op — dropped.**
- **Q4.1/Q4.2 RESOLVED:** Converting `MRecord` from `Dict` to flat list is deferred to a future pass. This plan focuses on Dict usage optimizations that don't change the type.

**Relationship to existing plans:**
- `compiler-perf-optimizations.md` — Covers MonoTraverse flip removal. Already partially implemented.
- `compiler-memory-efficiency-improvements.md` — Covers O(n²) `acc ++ [x]` fixes and other systemic issues. Complements this plan.

**Active recommendations** (by implementation order):
1. Rec 1: Structural sharing in eraseTypeVarsToErased via changed flags
2. Rec 5: Deforest/fuse List traversals
3. Rec 7: Reduce A2/A3 overhead in hot paths
4. Rec 4: Dict usage optimizations (foldl replacements, no type change)
5. Rec 6: Inline/specialize hot traversals
6. Rec 2: Memoize eraseTypeVarsToErased / hash-cons monotypes (deferred until post-profiling)

**Dropped:**
- ~~Rec 3: Cache monomorphized function bodies~~ — Already handled by Registry.

---

## Rec 1: Structural Sharing in `eraseTypeVarsToErased` via Changed Flags

### Problem
`eraseTypeVarsToErased` in `Monomorphized.elm:302` always rebuilds the entire type tree even when no MVars exist. Called from `patchNodeTypesToErased` (Monomorphize.elm:578) on every non-cycle, non-port, non-extern node, plus via `mapExprTypes` which walks every expression in those nodes.

### Design: Boolean Changed-Flag Pattern

Since `==` is structural (not reference) equality, we cannot cheaply check "did the recursive call return the same object?" Instead, every recursive call returns `(Bool, MonoType)` where the Bool indicates whether any change was made.

**Core helper type:** `(Bool, MonoType)` — `True` means something changed.

**Step 1: Add `containsAnyMVar : MonoType -> Bool`**

File: `compiler/src/Compiler/AST/Monomorphized.elm`

```elm
containsAnyMVar : MonoType -> Bool
containsAnyMVar monoType =
    case monoType of
        MVar _ _ -> True
        MList t -> containsAnyMVar t
        MFunction args result -> List.any containsAnyMVar args || containsAnyMVar result
        MTuple elems -> List.any containsAnyMVar elems
        MRecord fields -> Dict.foldl (\_ t acc -> acc || containsAnyMVar t) False fields
        MCustom _ _ args -> List.any containsAnyMVar args
        _ -> False
```

This already follows the exact pattern of `containsCEcoMVar` (line 354) but matches all MVar constraints.

**Step 2: Add internal `eraseTypeVarsToErasedHelp` returning `(Bool, MonoType)`**

```elm
eraseTypeVarsToErasedHelp : MonoType -> ( Bool, MonoType )
eraseTypeVarsToErasedHelp monoType =
    case monoType of
        MVar _ _ ->
            ( True, MErased )

        MList t ->
            let ( changed, newT ) = eraseTypeVarsToErasedHelp t
            in if changed then ( True, MList newT ) else ( False, monoType )

        MFunction args result ->
            let
                ( argsChanged, newArgs ) = listMapChanged eraseTypeVarsToErasedHelp args
                ( resultChanged, newResult ) = eraseTypeVarsToErasedHelp result
            in
            if argsChanged || resultChanged then
                ( True, MFunction newArgs newResult )
            else
                ( False, monoType )

        MTuple elems ->
            let ( changed, newElems ) = listMapChanged eraseTypeVarsToErasedHelp elems
            in if changed then ( True, MTuple newElems ) else ( False, monoType )

        MRecord fields ->
            let ( changed, newFields ) = dictMapChanged eraseTypeVarsToErasedHelp fields
            in if changed then ( True, MRecord newFields ) else ( False, monoType )

        MCustom can name args ->
            let ( changed, newArgs ) = listMapChanged eraseTypeVarsToErasedHelp args
            in if changed then ( True, MCustom can name newArgs ) else ( False, monoType )

        _ ->
            ( False, monoType )
```

**Step 3: Rewrite `eraseTypeVarsToErased` as thin wrapper**

```elm
eraseTypeVarsToErased : MonoType -> MonoType
eraseTypeVarsToErased monoType =
    Tuple.second (eraseTypeVarsToErasedHelp monoType)
```

**Step 4: Implement `listMapChanged` helper**

```elm
listMapChanged : (a -> ( Bool, a )) -> List a -> ( Bool, List a )
listMapChanged f list =
    listMapChangedHelp f list False []

listMapChangedHelp : (a -> ( Bool, a )) -> List a -> Bool -> List a -> ( Bool, List a )
listMapChangedHelp f remaining anyChanged acc =
    case remaining of
        [] ->
            if anyChanged then
                ( True, List.reverse acc )
            else
                ( False, [] )  -- caller discards this; uses original

        x :: xs ->
            let ( changed, newX ) = f x
            in listMapChangedHelp f xs (anyChanged || changed) (newX :: acc)
```

**Important:** When `anyChanged` is False, the caller returns the original `monoType` (not the accumulated list), so the empty list `[]` in the False branch is never used.

**Step 5: Implement `dictMapChanged` helper**

```elm
dictMapChanged : (v -> ( Bool, v )) -> Dict comparable v -> ( Bool, Dict comparable v )
dictMapChanged f dict =
    Dict.foldl
        (\key val ( changed, acc ) ->
            let ( valChanged, newVal ) = f val
            in ( changed || valChanged, Dict.insert key newVal acc )
        )
        ( False, Dict.empty )
        dict
        |> (\( changed, newDict ) ->
                if changed then ( True, newDict ) else ( False, dict )
           )
```

**Note:** This still rebuilds the Dict even when nothing changed (because Dict.foldl always iterates). An optimization would be to short-circuit, but Dict doesn't support early exit. The key win is that the *caller* avoids wrapping in MRecord when unchanged. For a future refinement, we could first check `containsAnyMVar` on the whole record to skip the Dict traversal entirely.

**Step 5b: Top-level guard optimization**

Add a fast-path guard to `patchNodeTypesToErased` in Monomorphize.elm:

```elm
patchNodeTypesToErased : Mono.MonoNode -> Mono.MonoNode
patchNodeTypesToErased node =
    case node of
        Mono.MonoDefine expr t ->
            -- Fast path: if the node-level type has no MVars, the expression
            -- types likely don't either. But expressions may have MVars in
            -- sub-expressions even if the top-level type doesn't, so we
            -- can only skip the type erasure, not the expression walk.
            Mono.MonoDefine
                (eraseExprTypeVars expr)
                (Mono.eraseTypeVarsToErased t)
        ...
```

Actually, the real savings come from the changed-flag pattern inside the recursion. The top-level guard would only help if we could cheaply determine "this entire expression tree has no MVars" — which would require a separate tree walk (negating the benefit). So skip the top-level guard; the changed-flag pattern handles it bottom-up.

**Step 6: Apply same pattern to `eraseCEcoVarsToErased`**

Identical structure to Steps 2-3, but matching `MVar _ CEcoValue -> (True, MErased)` and `MVar _ CNumber -> (False, monoType)`.

**Step 7: Apply changed-flag pattern to `mapExprTypes`**

The expression-level traversal (`mapExprTypes` / `mapOneExprType`) in Monomorphize.elm:638-712 also always rebuilds every expression node. Apply the same changed-flag pattern:

- Change `mapOneExprType` to return `(Bool, MonoExpr)`.
- In `mapExprTypes`, use a variant of `mapExpr` that propagates the flag, or write a specialized `mapExprTypesChanged` that directly recurses.
- When the type function returns `(False, _)` for a node's type AND no child changed, return the original expression.

This is a larger change because it touches the MonoTraverse integration. Consider implementing as a separate step after the MonoType-level change is validated.

### Files
- `compiler/src/Compiler/AST/Monomorphized.elm` — `eraseTypeVarsToErased`, `eraseCEcoVarsToErased`, new helpers, `containsAnyMVar`
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm` — `mapExprTypes`/`mapOneExprType` (Step 7)
- Possibly `compiler/src/Compiler/GlobalOpt/MonoTraverse.elm` if Step 7 needs a changed-flag variant of `mapExpr`

### Risks
- Low for Steps 1-6 (MonoType level). Pure refactor, same semantics.
- Medium for Step 7 (expression level). Touching MonoTraverse requires care.
- The `listMapChanged` helper allocates a `(Bool, a)` tuple per element. In Elm on V8, tuples are objects, so this adds allocation. However, the savings from not rebuilding the parent MFunction/MTuple/MCustom when nothing changed should dominate.

### Testing
- `cd compiler && npx elm-test-rs --fuzz 1`
- `cmake --build build --target check`

---

## Rec 4: Dict Usage Optimizations (No Type Changes)

### Problem
`Dict.map/get/insertHelp` are a large fraction of non-GC time. Many Dict operations can be replaced with cheaper alternatives.

### Approach

**Step 1: Replace `Dict.values + List.foldl` with `Dict.foldl`**

In `Specialize.elm:1067`:
```elm
-- Before:
instancesList = Dict.values compare topEntry.instances
... List.foldl (\info (defsAcc, stAcc) -> ...) ([], state) instancesList

-- After:
Dict.foldl compare (\_ info (defsAcc, stAcc) -> ...) ([], state) topEntry.instances
```

**Step 2: Replace `Dict.map (\_ t -> f t)` with `Dict.foldl` + `Dict.insert` where the function rarely changes values**

For the erasure case, this is handled by Rec 1's `dictMapChanged`. For other cases in Specialize.elm and GlobalOpt, audit each `Dict.map` to see if it can benefit from the same pattern.

**Step 3: Audit `Dict.foldl` in `containsCEcoMVar` pattern**

The existing `containsCEcoMVar` at Monomorphized.elm:372 already uses `Dict.foldl` with short-circuit via `||`. Good pattern — ensure all similar "any" checks on Dict use this rather than `Dict.values |> List.any`.

**Step 4: Replace varTypes environment with more efficient pattern**

In Specialize.elm, `varTypes` is a Dict cleared on function entry. If it's typically small (< 8 entries), consider:
- Using `List (Name, MonoType)` with linear scan for lookup
- This avoids Dict tree allocation overhead for small maps

Only do this if profiling confirms small size. Otherwise, leave as-is.

### Files
- `compiler/src/Compiler/Monomorphize/Specialize.elm`
- `compiler/src/Compiler/AST/Monomorphized.elm` (already covered by Rec 1)

### Risks
- Low. Mechanical replacements.

### Testing
- Full test suite.

---

## Rec 5: Deforest and Fuse List Traversals

### Problem
List operations (List.map, List.foldrHelper, _List_Cons) are huge contributors to allocation. Many passes build intermediate lists only to immediately fold/map again.

### Approach

**Step 1: Audit and catalog chained list operations in hot files**

Target files (by Dict/List op count):
- `Specialize.elm` — 39 List ops, 6 Dict ops
- `MonoInlineSimplify.elm` — 18 Dict ops (many with list intermediaries)
- `MonoGlobalOptimize.elm` — 11 Dict ops

For each, identify:
- `List.map f (List.map g xs)` → fuse to `List.map (f >> g) xs`
- `List.map f xs |> List.filter p` → single fold
- `List.map f xs` where `f` rarely changes elements → `listMapChanged` pattern

**Step 2: Fuse obvious map chains in Specialize.elm**

Example patterns to find and fuse:
```elm
-- Before:
List.map (\( n, ty ) -> ( n, Mono.eraseTypeVarsToErased ty )) params

-- After (if using changed-flag):
let ( changed, newParams ) = listMapChanged (\( n, ty ) ->
        let ( c, newTy ) = Mono.eraseTypeVarsToErasedHelp ty
        in ( c, ( n, newTy ) )) params
```

**Step 3: Replace `List.foldr` with `List.foldl + List.reverse` where safe**

In `processCallArgs` (Specialize.elm:1316), `List.foldr` over args builds three accumulators. Since all three are list accumulators built with `::`, switching to `List.foldl` + reverse at the end avoids the stack overhead of `foldr`.

**Step 4: Eliminate intermediate list construction in `specializeRecordFields`**

At Specialize.elm:2031, `Dict.foldl` builds a reversed list. Add explicit `List.reverse` at the end (or switch to `Dict.foldr` if the Dict supports it efficiently).

**Step 5: Apply to MonoTraverse.elm children iteration**

In `mapExprChildren` and `foldExprChildren`, check for patterns where lists of children are constructed, mapped, then immediately consumed. If the child list is only iterated once, inline the iteration.

### Files
- `compiler/src/Compiler/Monomorphize/Specialize.elm`
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm`
- `compiler/src/Compiler/GlobalOpt/MonoTraverse.elm`
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

### Risks
- Low-Medium. Each fusion is local. Risk of order bugs if foldl/foldr swap is done without checking.

### Testing
- Full test suite after each file's changes.

---

## Rec 6: Inline and Specialize Hot Traversals

### Problem
`MonoTraverse.mapExpr` dispatches generically through `mapExprChildren` + a callback. For the erasure use case, this creates unnecessary closure allocations and indirection.

### Approach

**Step 1: Write specialized `eraseExprTypeVarsDirect`**

Instead of:
```elm
eraseExprTypeVars = mapExprTypes Mono.eraseTypeVarsToErased
-- which expands to:
-- Traverse.mapExpr (mapOneExprType Mono.eraseTypeVarsToErased)
```

Write a direct recursive function that pattern-matches on MonoExpr constructors and erases types inline, using the changed-flag pattern from Rec 1:

```elm
eraseExprTypeVarsDirect : Mono.MonoExpr -> Mono.MonoExpr
eraseExprTypeVarsDirect expr =
    case expr of
        Mono.MonoLiteral lit t ->
            let ( changed, newT ) = Mono.eraseTypeVarsToErasedHelp t
            in if changed then Mono.MonoLiteral lit newT else expr
        Mono.MonoClosure info body t ->
            let
                newBody = eraseExprTypeVarsDirect body
                ( tChanged, newT ) = Mono.eraseTypeVarsToErasedHelp t
                ( paramsChanged, newParams ) = listMapChanged ...
            in ...
        ...
```

This eliminates:
- The `mapOneExprType Mono.eraseTypeVarsToErased` closure allocation
- The `mapExpr` → `mapExprChildren` → callback indirection
- All intermediate node rebuilds when nothing changed

**Step 2: Keep generic `mapExprTypes` for non-hot uses**

Don't remove the generic version — it's useful for other callers. Just bypass it for the erasure hot path.

**Step 3: Evaluate whether to specialize GlobalOpt traversals**

Defer to profiling. MonoInlineSimplify's traversal is more complex and harder to specialize.

### Files
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

### Risks
- Medium. The specialized function must handle all MonoExpr constructors. If new constructors are added, both the generic and specialized versions need updating.
- Mitigated by: the specialized version only handles type erasure (simpler than a general transform).

### Testing
- Full test suite.

### Open Questions
- **Q6.1:** How many MonoExpr constructors exist? If > 20, the specialized function is large but still manageable.
- **Q6.2:** Should we combine Steps 1-6 of Rec 1 with Rec 6 into a single "optimized erasure" implementation? This would avoid doing Rec 1 at MonoType level first and then redoing it at expression level.

---

## Rec 7: Reduce A2/A3 Overhead in Hot Paths

### Problem
A2/A3 (curried function application wrappers) account for ~10% of non-GC time and allocate closure objects. Every `List.map f list` and `Dict.map f dict` invokes A2 internally. The goal is to **eliminate the higher-order call entirely** by replacing generic HOF usage with direct recursive functions.

### Approach

**Step 1: Replace `List.map f xs` with direct recursive helpers in erasure hot paths**

Pattern:
```elm
-- Before (A2 overhead per element):
List.map eraseTypeVarsToErased args

-- After (direct recursion, no A2):
eraseTypeList : List MonoType -> List MonoType
eraseTypeList list =
    case list of
        [] -> []
        x :: xs -> eraseTypeVarsToErased x :: eraseTypeList xs
```

Combined with the changed-flag pattern from Rec 1, this becomes `listMapChanged eraseTypeVarsToErasedHelp` — which is already a direct recursive function that avoids A2.

Target sites:
- `Monomorphized.elm:313` — `List.map eraseTypeVarsToErased args`
- `Monomorphized.elm:317` — `List.map eraseTypeVarsToErased elems`
- `Monomorphized.elm:323` — `List.map eraseTypeVarsToErased args`
- `Monomorphize.elm:588` — `List.map (\( n, ty ) -> ...) params`
- `Monomorphize.elm:666` — `List.map (\( n, pt ) -> ...) info.params`

**Step 2: Replace `Dict.map (\_ t -> f t)` with direct fold-based traversal**

```elm
-- Before (A2 overhead per entry + lambda allocation):
Dict.map (\_ t -> eraseTypeVarsToErased t) fields

-- After (direct, no lambda, no A2):
-- Already handled by dictMapChanged from Rec 1, which uses Dict.foldl directly.
```

**Step 3: Refactor hot APIs to take tuples/records instead of curried partial application**

Identify functions in Specialize.elm that are partially applied in tight loops, creating a PAP closure per call:
```elm
-- Before (creates closure for (specializeExpr subst) at each call):
List.map (\arg -> specializeExpr arg subst state) args

-- After (direct recursive function, no partial application):
specializeExprList : List TOpt.Expr -> TypeSubst -> State -> ( List Mono.MonoExpr, State )
specializeExprList args subst state =
    case args of
        [] -> ( [], state )
        x :: xs ->
            let ( monoX, st1 ) = specializeExpr x subst state
                ( monoXs, st2 ) = specializeExprList xs subst st1
            in ( monoX :: monoXs, st2 )
```

**Step 4: Specialize generic utilities used with fixed functions**

Where `Dict.map` or `List.map` is always called with the same transform (e.g., erasure), write a purpose-built function that does the iteration + transform in one pass without higher-order dispatch.

### Files
- `compiler/src/Compiler/AST/Monomorphized.elm`
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm`
- `compiler/src/Compiler/Monomorphize/Specialize.elm`

### Risks
- Low. Each change is mechanical.
- Readability slightly reduced by extracting lambdas to top-level, but the named functions are self-documenting.

### Testing
- Full test suite.

---

## Rec 2: Memoize eraseTypeVarsToErased / Hash-Cons MonoTypes (Deferred)

### Problem
Structurally identical MonoTypes are rebuilt many times across different specializations.

### Status: DEFERRED

Defer until after Recs 1, 4, 5, 6, 7 are implemented and profiled. If structural sharing (Rec 1) eliminates most unnecessary rebuilds, memoization may not be needed. If profiling still shows high duplication of identical MonoType constructions, revisit.

### Approach (if needed)
- Thread a `Dict String MonoType` cache through the erasure pass
- Key = canonical string of input MonoType (via `toComparableMonoType` which already exists at Monomorphized.elm:10)
- Convert `Array.map` in `patchNodeTypesToErased` to `Array.foldl` to thread cache

### Open Questions
- **Q2.1:** What is the duplication rate? Need profiling.
- **Q2.2:** Is `toComparableMonoType` cheap enough to use as cache key?

---

## Implementation Order

| Phase | Rec | Description | Effort | Impact |
|-------|-----|-------------|--------|--------|
| **1a** | 1 (Steps 1-6) | Changed-flag pattern for MonoType erasure | Small | High |
| **1b** | 7 (Steps 1-2) | Direct recursive helpers replacing `List.map`/`Dict.map` in erasure | Small | Medium |
| **1c** | 4 (Step 1) | `Dict.values+foldl` → `Dict.foldl` in Specialize.elm | Small | Low-Medium |
| **2a** | 5 (Steps 1-4) | List deforestation in Specialize.elm | Medium | Medium-High |
| **2b** | 7 (Steps 3-4) | Direct calls, flatten curried funcs | Small | Low-Medium |
| **2c** | 1 (Step 7) | Changed-flag pattern for expression-level erasure | Medium | High |
| **3** | 6 | Specialized `eraseExprTypeVarsDirect` | Medium | Medium |
| **4** | 2 | Memoization (only if profiling justifies) | Large | Unknown |

**Phase 1** (low-hanging fruit): Rec 1 MonoType changed-flags + Rec 7 direct recursive helpers + Rec 4 Dict.foldl. All small, independent, high ROI. Note: Rec 1 and Rec 7 Steps 1-2 overlap heavily — the `listMapChanged`/`dictMapChanged` helpers from Rec 1 already eliminate A2 overhead for erasure paths.

**Phase 2** (systematic): List deforestation + expression-level changed flags. Medium effort, high cumulative impact.

**Phase 3** (specialization): Only if Phase 2 profiling shows traversal overhead remains significant.

**Phase 4** (memoization): Only if profiling after Phase 1-3 shows repeated identical type construction.

---

## Prerequisites

- Read `design_docs/invariants.csv` before modifying any type representation
- After each phase, run:
  - `cd compiler && npx elm-test-rs --fuzz 1` (frontend tests)
  - `cmake --build build --target check` (E2E tests)
- Profile before Phase 1 and after each phase to measure actual impact

---

## Remaining Open Questions

| ID | Question | Blocking? |
|----|----------|-----------|
| Q2.1 | What is the MonoType duplication rate across specializations? | Yes for Rec 2 (deferred) |
| Q2.2 | Is `toComparableMonoType` cheap enough as cache key? | Yes for Rec 2 (deferred) |
| Q5.1 | Which list chains in Specialize.elm are hottest? | No (nice to have for prioritization) |
| Q6.1 | How many MonoExpr constructors exist? | No (can count from code) |
| Q6.2 | Should Rec 1 + Rec 6 be combined into a single implementation? | No (design choice, recommended: implement separately for easier validation) |
| Q7.1 | How many `List.map`/`Dict.map` call sites in Specialize.elm are in tight loops vs. one-shot? | No (helps prioritize which to convert to direct recursion) |

## Assumptions

1. The compiler is compiled by guida (Elm-in-Elm) running on Node.js/V8, so V8's generational GC is the primary bottleneck.
2. The 72.5% GC time figure is from a representative large Elm program.
3. `eraseTypeVarsToErased` is called on every specialized node (confirmed from code).
4. `(Bool, MonoType)` tuples in the changed-flag pattern are cheap V8 objects that will be short-lived and collected in the nursery.
5. Most fully-specialized MonoTypes contain zero MVars, so the changed-flag fast path (return False + original) will fire on the majority of types.
6. Dict operations use Elm's standard red-black tree Dict (O(log n) per op, allocation-heavy).
7. The existing `compiler-perf-optimizations.md` Item 1 (flip removal) is already implemented or will be done independently.
