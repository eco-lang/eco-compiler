# Plan: Compiler Memory Reduction

Systematic reduction of the Elm compiler's memory footprint by fixing algorithmic inefficiencies,
eliminating redundant allocations, and improving data structure usage.

## Context

The compiler is written in Elm and compiled to JavaScript. Elm's persistent data structures
mean that `++` (list append) is O(n) in the left operand, `Dict` operations are O(log n),
and `::` (cons) is O(1). Many patterns in the codebase use `acc ++ [item]` inside folds,
turning O(n) traversals into O(n²). Additionally, `Data.Map` re-sorts on every read access,
and several other patterns create unnecessary intermediate allocations.

**Profiling:** Use `/usr/bin/time -v` to measure peak RSS before and after changes.

---

## P0 — Critical

### P0-1: Replace `acc ++ [item]` with cons-and-reverse

**Problem:** 213 occurrences of `++ [` across 41 files. When used in a fold accumulator,
this is O(n²) total because `++` copies the entire left list for each append.

**Scope:** Every file listed below. The fix is mechanical: replace `acc ++ [item]` inside
`foldl`/recursive functions with `item :: acc`, then add a `List.reverse` at the end.

**Hotspot files (by occurrence count):**

| File | Count | Notes |
|------|-------|-------|
| `Generate/MLIR/Expr.elm` | 59 | IR op accumulation |
| `Generate/MLIR/TailRec.elm` | 24 | IR op accumulation |
| `GlobalOpt/MonoInlineSimplify.elm` | 16 | Fold accumulators |
| `Common/Format/Render/Box.elm` | 16 | String rendering |
| `Generate/MLIR/Patterns.elm` | 14 | IR op accumulation |
| `Reporting/Error/Canonicalize.elm` | 11 | Error list building |
| `Generate/MLIR/BytesFusion/Emit.elm` | 11 | IR op accumulation |
| `GlobalOpt/Staging/Rewriter.elm` | 10 | Fold accumulators |
| `Common/Format/Cheapskate/Parse.elm` | 5 | Markdown parsing |
| `Generate/MLIR/Functions.elm` | 4 | IR op accumulation |
| Remaining 31 files | 1–3 each | Mixed |

**Key functions to fix first (highest leverage):**

1. `MonoTraverse.traverseList` (`compiler/src/Compiler/GlobalOpt/MonoTraverse.elm:600-610`) —
   Used by every GlobalOpt pass on every list in every expression. Current code:
   ```elm
   traverseList f ctx list =
       List.foldl
           (\item ( acc, c ) ->
               let ( newItem, c1 ) = f c item
               in ( acc ++ [ newItem ], c1 )
           )
           ( [], ctx )
           list
   ```
   Fix: `( newItem :: acc, c1 )` then `|> Tuple.mapFirst List.reverse` after the foldl.

2. All MLIR op-accumulation sites — These accumulate IR operations (`ops ++ result.ops ++ [newOp]`).
   Each expression node appends ops, and deeply nested expressions cause quadratic growth.
   Fix: use **reversed-accumulator pattern** with a single final reverse, following the proven
   approach already used in `BytesFusion/Emit.elm` (lines 65–79). The final consumer
   `mkRegionFromOps` (Expr.elm:3810) already reverses ops, so this integrates naturally.
   Ops lists are never inspected during accumulation — they are purely threaded through — so
   reversed accumulation is always safe.

**Approach:**
- Work file-by-file, largest count first.
- For each `++ [` site, determine whether it's inside a fold/recursive accumulator (fix needed)
  or a small constant append like `paramTypes ++ [I1, retTy]` (leave as-is — O(1) cost).
- Where the fold result feeds into another consumer, verify the consumer doesn't depend on
  append-order semantics during the fold (it shouldn't, but check).
- Run `elm-test-rs` after each batch of files.

**Verification:** `npx elm-test-rs --project build-xhr --fuzz 1` + `cmake --build build --target check`

---

### P0-2: Remove redundant re-sorting from `Data.Map.keys/values/toList`

**Problem:** `Data.Map.keys`, `values`, and `toList` all sort on every call:
```elm
keys keyComparison (D dict) =
    Dict.values dict
        |> List.sortWith (\( k1, _ ) ( k2, _ ) -> keyComparison k1 k2)
        |> List.map Tuple.first
```
There are 138 call sites across 52 files. Many are in hot loops (type solving, monomorphization,
MLIR generation). Each call is O(n log n) when it should be O(n).

**Analysis (resolved):** All `toComparable` functions used with `Data.Map` in the entire
compiler are `identity` (43 concrete call sites audited, zero exceptions). Since `identity`
is trivially order-preserving (`compare a b == compare (identity a) (identity b)`), the
underlying `Dict.Dict comparable (k, v)` is already sorted in the correct order. The
`List.sortWith` in `keys`, `values`, and `toList` is provably redundant and can be safely
removed.

**Fix:** Remove the `List.sortWith` calls:
```elm
keys keyComparison (D dict) =
    Dict.values dict
        |> List.map Tuple.first

values keyComparison (D dict) =
    Dict.values dict
        |> List.map Tuple.second

toList keyComparison (D dict) =
    Dict.values dict
```

The `keyComparison` parameter becomes unused in these functions. It can be left in place
for API compatibility or removed in a follow-up.

**Risk:** None — `identity` is the only `toComparable` in use. Output order is unchanged.

**Verification:** Same as P0-1.

---

## P1 — High Impact

### P1-1: Replace bytes-encode + hex test deduplication with comparable key

**Problem:** `DecisionTree.testsAtPath` (`compiler/src/Compiler/LocalOpt/Typed/DecisionTree.elm:340-356`)
deduplicates tests by encoding each `Test` value to binary bytes, then converting to a hex string,
just for `EverySet` membership checking:
```elm
EverySet.member (testEncoder >> Bytes.Encode.encode >> Hex.Convert.toString) test visitedTests
```
This allocates a `Bytes` buffer and a hex string for every membership check. Called at every
decision point in every case expression.

The `Test` type is:
```elm
type Test
    = IsCtor IO.Canonical Name.Name Index.ZeroBased Int Can.CtorOpts
    | IsCons | IsNil | IsTuple
    | IsInt Int | IsChr String | IsStr String | IsBool Bool
```

**Fix:** Write a `testToComparable : Test -> String` function that produces a simple string key
directly, without going through bytes encoding. For example:
```elm
testToComparable test =
    case test of
        IsCtor (IO.Canonical pkg mod) name _ _ _ ->
            "C" ++ pkg ++ "/" ++ mod ++ "." ++ name
        IsCons -> "cons"
        IsNil -> "nil"
        IsTuple -> "tup"
        IsInt n -> "I" ++ String.fromInt n
        IsChr c -> "H" ++ c
        IsStr s -> "S" ++ s
        IsBool b -> if b then "Bt" else "Bf"
```
Then use `EverySet.member testToComparable` instead.

Also applies to the 3 other sites using the same pattern (check `EverySet.insert` with the
same encoder).

**Verification:** Same as P0-1.

---

### P1-2: Evaluate `Can.Type` on every `TypedOptimized.Expr` variant

**Problem:** Every expression variant in `TypedOptimized.Expr` carries a `Can.Type`. This type
is a full recursive tree (function types, record types, etc.) that can be 100-300+ bytes per
expression node. These types are carried through typed optimization, monomorphization, GlobalOpt,
and into MLIR generation.

**Investigation needed:** Determine which passes actually read the type from each expression
and whether it could be stored externally (e.g., in a `Dict NodeId Can.Type`) and looked up
on demand, rather than embedded in every constructor.

**Approach:**
- Use `find_referencing_symbols` to determine how many passes actually read types from
  expressions vs. just threading them through.
- If most passes just thread types through, consider separating the type store.
- This is a larger architectural change — plan carefully and evaluate ROI before implementing.

**Risk:** High implementation complexity. Consider deferring if simpler wins are sufficient.

---

### P1-3: Evaluate Source AST comment wrapping overhead

**Problem:** The Source AST wraps every node with comment types (`C1`, `C2`, `C2Eol`) that
carry `List Comment`. Most nodes have no comments, so this is `[]` — but Elm still allocates
a list cell per wrapper. Every parsed expression, pattern, and type annotation goes through
this wrapping.

**Investigation needed:** Measure the actual overhead. In compiled JS, `[]` is a shared constant
so the allocation cost may be negligible. The wrapping constructor itself (e.g., `C1 [] expr`)
still allocates one cell per node.

**Approach:**
- If overhead is meaningful: consider using `Maybe (List Comment)` so `Nothing` is a shared
  constant with no inner allocation.
- Or: only attach comments to declarations, not every sub-expression.
- Defer until profiling confirms this is significant in practice.

**Risk:** Touches every use of the Source AST. Large change surface.

---

## P2 — Medium Impact

### P2-1: Reduce GlobalOpt sequential full-AST rewrite passes

**Problem:** `MonoGlobalOptimize` runs 5 sequential full-AST rewrite passes:
AbiCloning, StagingRewriting, InlineSimplification, Uncurrying, etc. Each pass traverses and
reconstructs the entire AST using `MonoTraverse.traverseList` (which, once P0-1 is fixed, will
be O(n) per pass but still 5x traversal).

**Investigation needed:** Determine which passes could be fused into a single traversal.
Passes that don't depend on each other's results can potentially be combined.

**Approach:**
- Check pass dependencies: does pass N read results written by pass N-1?
- If AbiCloning is frequently a no-op, add a pre-check to skip it entirely.
- Consider fusing independent passes into a single traversal.

---

### P2-2: Embedded `Union` in `PCtor`

**Problem:** Every constructor pattern (`PCtor`) embeds a full `Can.Union` type definition,
duplicating the union definition once per constructor usage in pattern matching. The same
union definition may appear hundreds of times for commonly-used types.

**Approach:**
- Replace the embedded `Can.Union` with a reference (module name + type name) and look up
  the union definition from a shared registry.
- Requires threading a union lookup context through pattern compilation.

---

### P2-3: MLIR Context unbounded growth

**Problem:** The `Context` record used during MLIR generation accumulates `pendingLambdas`,
`kernelDecls`, `typeRegistry`, and `signatures` without pruning. For large programs, this
grows proportionally to program size.

**Approach:**
- Investigate whether completed lambdas can be emitted and removed from `pendingLambdas`.
- Consider chunking or streaming MLIR output rather than accumulating everything in memory.

---

### P2-4: Fix `NonEmptyList.cons` naming and latent ordering bug

**Problem:** `NonEmptyList.cons` (`compiler/src/Compiler/Data/NonEmptyList.elm:54-55`) is
**misnamed**. Despite the name `cons`, it appends to the end (snoc):
```elm
cons a (Nonempty b bs) =
    Nonempty b (bs ++ [ a ])
```
This is O(n) per call. The docstring correctly says "Add an element to the end" but the
function name contradicts standard FP convention where `cons` means prepend.

**Analysis (resolved):** There are 3 call sites:

1. `Utils.Main.nonEmptyListTraverse` (line 550) — uses `List.foldl` + `cons`. Because foldl
   processes left-to-right and cons appends to end, order is preserved. **Works correctly.**

2. `Utils.Main.sequenceNonemptyListResult` (line 430) — uses `List.foldr` + `cons`. Because
   foldr processes right-to-left and cons appends to end, the tail gets **reversed**. This is
   a **latent bug**: input `Nonempty 1 [2, 3]` produces `Nonempty 1 [3, 2]`.

3. `Terminal/Test.elm` (lines 166–167) — pipeline `|> NE.cons x |> NE.cons y`. Intent appears
   to be prepending high-priority source directories, but cons actually appends them to the
   end. **Likely wrong priority order.**

**Fix:**
1. Rename `cons` to `snoc` (or `append`) to match actual semantics.
2. Add a true `prepend` function: `prepend a (Nonempty b bs) = Nonempty a (b :: bs)` — O(1).
3. Fix `sequenceNonemptyListResult`: change `List.foldr` to `List.foldl` (with the snoc-renamed
   function) to preserve element order.
4. Review `Terminal/Test.elm` to determine if `prepend` is the correct operation there.

**Verification:** Same as P0-1.

---

## P3 — Lower Impact

### P3-1: No memoization on type substitution

**Problem:** `Monomorphize/TypeSubst.applySubst` walks type trees without caching results.
When the same type is specialized multiple times with the same substitution, the work is
repeated.

**Approach:** Add a simple memo `Dict` keyed by `(TypeId, SubstitutionId)` to cache results.
Evaluate whether the hit rate justifies the overhead of maintaining the cache.

---

### P3-2: Closure capture analysis is quadratic

**Problem:** `Monomorphize/Closure.elm` performs a full tree walk per lambda to find captured
variables. For modules with many lambdas, this is O(lambdas × AST-size).

**Approach:** Consider computing captured variables in a single bottom-up pass over the AST,
collecting free variables at each node.

---

### P3-3: Type registry linear scan

**Problem:** The monomorphization type registry uses linear scans for some lookups, causing
O(n²) behavior for programs with many distinct monomorphic types.

**Approach:** Replace linear scans with `Dict`-based lookups where applicable.

---

### P3-4: SpecializationRegistry forward+reverse mapping duplication

**Problem:** `SpecializationRegistry` stores both a forward mapping (generic → specializations)
and a reverse mapping (specialization → generic), doubling memory for the registry.

**Approach:** Evaluate whether the reverse mapping is needed at all call sites. If it's only
needed rarely, compute it on demand instead of maintaining it.

---

### P3-5: MonoPath carries MonoType at every segment

**Problem:** Each segment of a `MonoPath` carries a `MonoType`, creating a recursive type tree
per path segment. Paths with many segments accumulate significant type data.

**Approach:** Store types externally and reference them by index, or only attach types at
leaf segments where they're actually needed.

---

### P3-6: CaptureABI duplicates types from ClosureInfo

**Problem:** `CaptureABI` stores type lists that are already present in the corresponding
`ClosureInfo`, resulting in redundant memory usage.

**Approach:** Remove the duplicated fields from `CaptureABI` and reference `ClosureInfo`
directly.

---

## Implementation Order

Recommended execution sequence based on impact-to-effort ratio:

1. **P0-1** — `acc ++ [item]` fix (mechanical, high impact, low risk)
2. **P0-2** — `Data.Map` sort removal (safe — all toComparable is `identity`)
3. **P1-1** — Test dedup comparable key (small scope, clear win)
4. **P2-4** — `NonEmptyList.cons` rename + bug fixes (small scope, fixes latent bug)
5. **P2-1** — GlobalOpt pass fusion investigation
6. **P1-2** — `Can.Type` on Expr evaluation (investigation first)
7. **P1-3** — Comment wrapping evaluation (investigation first)
8. **P2-2** — PCtor Union dedup
9. **P2-3** — Context growth
10. **P3-1 through P3-6** — Lower impact items as time permits

---

## Assumptions

1. The existing test suites (`elm-test-rs` + `cmake --build build --target check`) provide
   sufficient coverage to catch ordering regressions from these changes.

2. All `toComparable` functions used with `Data.Map` are `identity` (verified by exhaustive
   audit of all 43 concrete call sites — no exceptions found).

3. For MLIR op accumulation, the reversed-accumulator pattern (proven in `BytesFusion/Emit.elm`)
   is the right approach. DLists add complexity without meaningful benefit since ops are never
   inspected during accumulation and the final consumer already reverses.
