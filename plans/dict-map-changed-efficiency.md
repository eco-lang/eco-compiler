# Efficient `dictMapChanged` and Changed-Flag Collection Operations

## Problem Statement

Profiling the Stage 5 monomorphization pipeline reveals that `dictMapChanged` is a
major performance bottleneck. During the "Type patching + graph assembly" phase:

- Dict operations consume **~22%** of total JavaScript execution time
  (insert 4.3% + insertHelp 3.5% + balance 3.6% + RBNode ctor 4.3% + foldl 3.3% + A5 4.0%)
- GC takes **27.8%** of total time, driven largely by allocation pressure from dict rebuilding
- `eraseCEcoVarsToErasedHelp` alone takes **7.8%** self-time, calling `dictMapChanged`
  on every `MRecord` type encountered during type erasure

The root cause is that `dictMapChanged` unconditionally rebuilds the entire dictionary
via `Dict.foldl` + `Dict.insert`, which is **O(n log n)** with heavy allocation, even
when **no values changed** (the common case during type erasure, where most types have
no MVars to erase).

### Two Broken Implementations

There are two independent copies of `dictMapChanged`:

**1. `Monomorphized.elm` (line 585-604):** Folds over the dict, inserting every entry
into `Dict.empty`. Has a final `if changed` guard to return the original dict, but
the guard fires **after** the entire dict has already been rebuilt — the O(n log n)
work and allocations are wasted.

```elm
dictMapChanged f dict =
    let
        ( changed, newDict ) =
            Dict.foldl
                (\key val ( ch, acc ) ->
                    let
                        ( valChanged, newVal ) = f val
                    in
                    ( ch || valChanged, Dict.insert key newVal acc )
                )
                ( False, Dict.empty )
                dict
    in
    if changed then ( True, newDict )
    else ( False, dict )
```

**2. `TypeSubst.elm` (line 81-95):** Folds over the dict, inserting every entry back
into the original dict as accumulator. Has **no** final `if changed` guard at all —
always returns the rebuilt dict. Even worse allocation behavior because re-inserting
existing keys causes tree node recreation along every path.

```elm
dictMapChanged f dict =
    Dict.foldl
        (\key val ( anyChanged, acc ) ->
            let
                ( changed, newVal ) = f val
            in
            ( anyChanged || changed, Dict.insert key newVal acc )
        )
        ( False, dict )
        dict
```

### Callers (hot paths)

| Caller | File | Line | Frequency |
|--------|------|------|-----------|
| `eraseCEcoVarsToErasedHelp` (MRecord case) | Monomorphized.elm | 533 | Every `MRecord` in every expression in every spec during patching |
| `eraseTypeVarsToErasedHelp` (MRecord case) | Monomorphized.elm | 381 | Every `MRecord` in dead-value spec patching |
| `resolveMonoVarsHelp` (MRecord case) | TypeSubst.elm | 554 | Every `MRecord` during type variable resolution |

### Why the common case is "unchanged"

During type patching (Phase 2 of monomorphization), most expressions' type annotations
are already concrete — they don't contain any `MVar` nodes. The changed-flag pattern
is supposed to detect this and avoid rebuilding, but `dictMapChanged` defeats the
optimization by doing O(n log n) work regardless. For a codebase with many record types
(common in Elm — JSON decoders, model records, msg types), this is catastrophic.

---

## Plan

### Step 1: Fix `dictMapChanged` in `Monomorphized.elm` — Collect-and-Patch

**File:** `compiler/src/Compiler/AST/Monomorphized.elm` (lines 582-604)

Replace the current "rebuild from empty" implementation with a "collect updates, patch
if needed" approach:

```elm
{-| Map a changed-flag function over Dict values. Returns (True, newDict) if any
value changed, or (False, originalDict) if no value changed.

Optimized to avoid any Dict allocation when no values change (O(n) scan only).
When k values change, performs O(n + k log n) work instead of O(n log n).
-}
dictMapChanged : (v -> ( Bool, v )) -> Dict comparable v -> ( Bool, Dict comparable v )
dictMapChanged f dict =
    let
        updates =
            Dict.foldl
                (\key val acc ->
                    let
                        ( changed, newVal ) =
                            f val
                    in
                    if changed then
                        ( key, newVal ) :: acc

                    else
                        acc
                )
                []
                dict
    in
    case updates of
        [] ->
            ( False, dict )

        _ ->
            ( True, List.foldl (\( k, v ) d -> Dict.insert k v d) dict updates )
```

**Why this works:**

- **Unchanged case (common):** `Dict.foldl` runs f on each value but only tests the
  `changed` flag. No `Dict.insert` calls. No new dict nodes allocated. The accumulator
  stays as `[]` (the initial value — no cons cells). Cost: O(n) for the fold, zero
  allocation. Returns the original `dict` by identity.

- **Changed case (k entries change):** Collects k `(key, newVal)` pairs in a list
  (k cons cells), then applies k `Dict.insert` operations to the original dict.
  Cost: O(n + k log n). When k << n (typical: a record has 10 fields, 1 has an MVar),
  this is dramatically cheaper than rebuilding all n entries.

- **All-changed case:** O(n + n log n) = O(n log n), same asymptotic cost as before,
  but with better constants (inserts into an existing balanced tree vs building from
  empty). This case is rare during erasure passes.

**Allocation comparison for unchanged dict of n entries:**

| Implementation | Dict nodes | Tuples | List cells | Total |
|---------------|-----------|--------|------------|-------|
| Current (foldl+insert from empty) | O(n log n) | n | 0 | O(n log n) |
| New (collect-and-patch) | 0 | 0 | 0 | 0 |

### Step 2: Fix `dictMapChanged` in `TypeSubst.elm` — Same Pattern

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm` (lines 81-95)

Apply the same collect-and-patch pattern. The TypeSubst version is even more critical
to fix because it lacks the final `if changed` guard entirely — it always returns a
rebuilt dict.

```elm
dictMapChanged :
    (v -> ( Bool, v ))
    -> Dict.Dict Name v
    -> ( Bool, Dict.Dict Name v )
dictMapChanged f dict =
    let
        updates =
            Dict.foldl
                (\key val acc ->
                    let
                        ( changed, newVal ) =
                            f val
                    in
                    if changed then
                        ( key, newVal ) :: acc

                    else
                        acc
                )
                []
                dict
    in
    case updates of
        [] ->
            ( False, dict )

        _ ->
            ( True, List.foldl (\( k, v ) d -> Dict.insert k v d) dict updates )
```

### Step 3: Fix `listMapChanged` in `TypeSubst.elm` — Add Missing Guard

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm` (lines 58-78)

The current TypeSubst.elm `listMapChanged` always builds a reversed accumulator list,
even when nothing changes. It does have a final `if changed` guard (returning the
original list), but still allocates n cons cells for the reversed copy that gets
discarded.

Replace with the same pattern as Monomorphized.elm's version, which is already better
(it keeps the original reference via a separate `original` parameter). However, both
versions still allocate a full reversed copy.

For list arguments to type constructors (which are typically 1-5 elements), the
allocation is minor compared to the dict problem. Align the TypeSubst version with
the Monomorphized version for consistency:

```elm
listMapChanged :
    (a -> ( Bool, a ))
    -> List a
    -> ( Bool, List a )
listMapChanged f list =
    listMapChangedHelp f list list False []


listMapChangedHelp : (a -> ( Bool, a )) -> List a -> List a -> Bool -> List a -> ( Bool, List a )
listMapChangedHelp f remaining original anyChanged acc =
    case remaining of
        [] ->
            if anyChanged then
                ( True, List.reverse acc )

            else
                ( False, original )

        x :: xs ->
            let
                ( changed, newX ) =
                    f x
            in
            listMapChangedHelp f xs original (anyChanged || changed) (newX :: acc)
```

This is a direct copy of the Monomorphized.elm version. The improvement over the
current TypeSubst version is marginal (same allocation pattern, but the explicit
tail-recursive helper avoids the `List.foldl` closure allocation and the `step`
let-binding closure).

### Step 4: Deduplicate — Consider Consolidating the Two Copies

**Question for user:** The two modules (`Monomorphized.elm` and `TypeSubst.elm`) each
define their own `dictMapChanged` and `listMapChanged`. Should we:

**(A)** Keep both copies but ensure they use the same optimized implementation
(simpler, no import changes).

**(B)** Move the shared implementations to a common utility and import from both
modules (cleaner, but adds a dependency and may affect module compilation order).

**Recommendation:** **(A)** for now — the functions are small, and the two modules
have different type constraints (`Dict comparable v` vs `Dict.Dict Name v`). Keeping
aligned copies avoids import churn and potential circular dependency issues. If a third
copy appears, consolidation becomes worthwhile.

---

## Allocation Analysis: Why This Matters for GC

The profiling data shows **27.8% of total time in GC**. This is directly caused by
the current `dictMapChanged` pattern:

1. Every `Dict.insert` call allocates a new `RBNode_elm_builtin` (5-word constructor:
   color, key, value, left, right). For a dict of n entries, the foldl+insert rebuild
   creates O(n log n) new nodes — most are intermediates that become garbage immediately
   as the next insert replaces them.

2. Every step of the fold creates a `_Utils_Tuple2(changed, acc)` — n tuple allocations,
   all short-lived.

3. The `A5` cost (4.0% of total time) comes from `Dict.RBNode_elm_builtin` and
   `Dict.balance` being 5-argument functions, which require Elm's A5 partial
   application machinery on every call.

The collect-and-patch approach eliminates **all of these allocations** in the unchanged
case. In the changed case, it reduces them to k inserts (where k is the number of
changed entries, typically 0-2 for erasure passes).

**Expected GC impact:** Eliminating the dict rebuild in the unchanged case should
reduce GC time significantly. The dict operations account for ~22% of JS time and
are almost entirely allocation-driven. If 90% of `dictMapChanged` calls result in
no changes (a conservative estimate given that most types are concrete), this
eliminates ~20% of total allocation pressure, potentially halving GC time from
27.8% to ~14%.

---

## Files Modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/AST/Monomorphized.elm` | Replace `dictMapChanged` (lines 585-604) |
| `compiler/src/Compiler/Monomorphize/TypeSubst.elm` | Replace `dictMapChanged` (lines 81-95), replace `listMapChanged` (lines 58-78) |

No signature changes. No new exports. No callers need modification.

---

## Risks

1. **Semantic correctness:** The new `dictMapChanged` returns a dict that shares
   structure with the original (unchanged entries point to the same nodes). This is
   correct for immutable data — Elm dicts are persistent, so structural sharing is
   safe and expected.

2. **Order of updates:** `List.foldl` over the `updates` list inserts entries in
   reverse order of collection. Since each key appears at most once, insertion order
   doesn't affect the final dict semantics (Dict is keyed, not ordered by insertion).

3. **Edge case — empty dict:** When the input dict is empty, `Dict.foldl` returns `[]`
   immediately, and we return `( False, dict )`. Correct.

4. **Edge case — single entry:** A dict with one entry either produces `[]` (unchanged)
   or `[(key, newVal)]` (changed, one insert). Both correct.

5. **Performance regression in all-changed case:** When all n entries change, the new
   approach does n list cons cells + n dict inserts vs n dict inserts from empty.
   The list cons cells add ~2n words of allocation. However, inserting into an existing
   balanced tree is typically faster than building from empty (better cache behavior,
   shorter search paths). Net: neutral or slight improvement even in the worst case.

---

## Verification

1. **Frontend tests:** `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
2. **E2E tests:** `cmake --build build --target check`
3. **Correctness indicator:** If any type erasure behavior changed, E2E tests would
   produce different MLIR output, which would fail verification or produce wrong
   runtime behavior. The changed-flag semantics are preserved exactly.

---

## Future Considerations (Out of Scope)

These are noted for context but are **not part of this plan**:

- **Memoization of erasure results:** If the same `MonoType` appears in many
  expressions (likely for common record types), memoizing `eraseCEcoVarsToErasedHelp`
  results in a `Dict MonoType MonoType` cache could avoid redundant traversals entirely.
  This is a higher-impact optimization but requires threading a cache through the
  traversal and designing a suitable comparable key for `MonoType`.

- **Changed-flag `mapOneExprType`:** The current `mapExprTypes` always creates new
  expression nodes even when the type transformation returns the same type. A
  changed-flag variant of `mapOneExprType` that returns the original expression node
  unchanged would eliminate expression-level allocation waste. This is a larger change
  affecting `MonoTraverse.elm` and `Monomorphize.elm`.

- **Batch erasure:** Instead of erasing types per-spec (calling `eraseExprCEcoVars`
  once per spec node), a single pass over all specs could amortize traversal setup
  costs. This interacts with the per-spec patching logic in `assembleRawGraph`.

- **`listMapChanged` with short-circuit on first change:** For lists, a non-tail-
  recursive approach that walks the list without building an accumulator, and only
  allocates new cons cells from the first changed element onward, would reduce
  allocation for the unchanged prefix. Not tail-recursive, but safe for the short
  lists in type constructors (1-5 elements). Worth considering separately.
