# Compiler Memory Efficiency Improvements

## Overview

This plan addresses 25 memory inefficiency findings across the Elm compiler source, organized into 6 tiers by severity/impact. Each finding includes the specific code location, the problem, the fix, risk assessment, and testing strategy.

**Relationship to existing plans:**
- `mlir-pipeline-memory-reduction.md` — Covers Tier 6 / Finding 23 (pipeline scope tightening). Already has a detailed plan; this plan defers to it.
- `compiler-memory-reduction-scope-tightening.md` — Covers removing unused `GlobalTypeEnv` from post-mono pipeline. Already has a detailed plan; this plan defers to it.
- `globalopt-accidental-complexity-reduction.md` — Covers Tier 3 / Finding 12 (redundant GlobalOpt traversals). Already has a detailed plan; this plan defers to it.

---

## Tier 1: Systemic Issues

### Finding 1: O(n^2) list append `acc ++ [x]` (~50 sites)

**Problem:** Throughout the compiler, `List.foldl` accumulators use `acc ++ [newItem]` which copies the entire accumulated list on every iteration, producing O(n^2) total allocation.

**Affected files and sites (22 unique sites confirmed):**

| File | Line(s) | Context |
|------|---------|---------|
| `compiler/src/Compiler/GlobalOpt/MonoTraverse.elm` | 162, 608 | `traverseList` — shared traversal helper used by all GlobalOpt consumers |
| `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` | 776, 790, 807, 839, 879, 898, 912, 1032, 1684, 1698, 1715, 1729, 1769, 1788, 1802 | Rewrite/simplify fold accumulators |
| `compiler/src/Compiler/LocalOpt/Typed/Names.elm` | 412 | `traverse` — shared monadic traversal |
| `compiler/src/Compiler/LocalOpt/Erased/Names.elm` | 354 | `traverse` — same pattern, erased variant |
| `compiler/src/Compiler/LocalOpt/Typed/NormalizeLambdaBoundaries.elm` | 832 | Fresh-name fold |
| `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` | 57 | Lambda dedup fold |
| `compiler/src/Common/Format/Render/Box.elm` | 2995, 2998 | Type formatting |

**Additionally, the MLIR codegen has ~13 `accOps ++ nodeOps` sites (list-append in folds):**

| File | Line(s) |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Backend.elm` | 68, 94 |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | 846, 860, 891, 1342, 2720, 2768, 4104, 4118 |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | 496, 988 |
| `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` | 71 |

**Fix:** Replace `acc ++ [x]` with `x :: acc` and add `List.reverse` at the end. For `accOps ++ nodeOps` (chunk append), use `List.reverse nodeOps ++ accOps` and reverse at the end, or accumulate chunks into `List (List Op)` and `List.concat (List.reverse chunks)`.

**Detailed fix for the two shared traversal helpers:**

`MonoTraverse.traverseList` (line 600-610):
```elm
-- BEFORE:
traverseList f ctx list =
    List.foldl
        (\item ( acc, c ) ->
            let ( newItem, c1 ) = f c item
            in ( acc ++ [ newItem ], c1 )
        )
        ( [], ctx )
        list

-- AFTER:
traverseList f ctx list =
    let
        ( revAcc, finalCtx ) =
            List.foldl
                (\item ( acc, c ) ->
                    let ( newItem, c1 ) = f c item
                    in ( newItem :: acc, c1 )
                )
                ( [], ctx )
                list
    in
    ( List.reverse revAcc, finalCtx )
```

`Names.traverse` (Typed, line 412 and Erased, line 354):
```elm
-- BEFORE:
traverse func =
    List.foldl (\a -> andThen (\acc -> map (\b -> acc ++ [ b ]) (func a))) (pure [])

-- AFTER:
traverse func list =
    List.foldl (\a -> andThen (\acc -> map (\b -> b :: acc) (func a))) (pure []) list
        |> map List.reverse
```

All ~15 sites in `MonoInlineSimplify.elm` follow the same mechanical pattern and can be fixed identically.

For MLIR codegen `accOps ++ nodeOps` sites: use the chunk-accumulate pattern:
```elm
-- BEFORE (Backend.elm line 63-68):
( accOps ++ nodeOps, newCtx )

-- AFTER:
( nodeOps :: accChunks, newCtx )
-- then at the end: List.concat (List.reverse accChunks)
```

**Risk:** Low. List order must be preserved, so `List.reverse` is required. Mechanical, testable.

**Testing:** Run `npx elm-test-rs --project build-xhr --fuzz 1` and `cmake --build build --target check`. The MLIR output ordering is load-bearing, so E2E tests will catch any reversal mistakes.

---

### Finding 2: `Data.Map.foldl`/`foldr` materializes + sorts before folding (104 call sites)

**Problem:** `Data.Map.foldl` and `foldr` call `toList` which does `Dict.values dict |> List.sortWith (...)` — materializing the entire dictionary into a sorted list of `(k, v)` tuples before folding. This is O(n log n) sorting + O(n) tuple allocation, when a direct fold would be O(n) with zero allocation.

**Files:**
- `compiler/src/Data/Map.elm` lines 295-301 (`foldl`), 319-325 (`foldr`), 372-374 (`toList`)

**Fix:** Delegate to `Dict.foldl`/`Dict.foldr` which traverse the BST in-order without materializing:

```elm
-- BEFORE:
foldl keyComparison func initialResult dict =
    List.foldl
        (\( key, value ) result -> func key value result)
        initialResult
        (toList keyComparison dict)

-- AFTER:
foldl _keyComparison func initialResult (D dict) =
    Dict.foldl (\_ ( key, value ) result -> func key value result) initialResult dict
```

```elm
-- BEFORE:
foldr keyComparison func initialResult dict =
    List.foldr
        (\( key, value ) result -> func key value result)
        initialResult
        (toList keyComparison dict)

-- AFTER:
foldr _keyComparison func initialResult (D dict) =
    Dict.foldr (\_ ( key, value ) result -> func key value result) initialResult dict
```

**Important consideration:** The current `foldl`/`foldr` iterate in key-sorted order (via `toList` which sorts). `Dict.foldl`/`Dict.foldr` iterate in `comparable`-key order of the wrapper Dict's keys. If any call site depends on the specific iteration order matching the user-supplied `keyComparison`, this fix would change behavior.

**Investigation needed:** Audit the 104 call sites to determine whether any depend on iteration order. For most uses (accumulating sums, building sets, collecting values), order doesn't matter. For any that do depend on order (e.g., emitting output in a specific sequence), we'd need to keep `toList` for those specific sites.

**Risk:** Medium. The semantic change (iteration order) could affect determinism of output. Must audit call sites.

**Testing:** Full E2E test suite. Compare MLIR output before/after for identical programs to verify determinism.

---

### Finding 3: `Data.Map` stores every key twice (108 files)

**Problem:** `type Dict c k v = D (Dict.Dict c ( k, v ))` uses the `comparable` representation `c` as the Dict key and stores a `(k, v)` tuple as the value, meaning every key exists twice: once as the `c` key and once as the `k` in the tuple.

**File:** `compiler/src/Data/Map.elm` line 73-74

**Fix options:**

Option A (minimal): Change to `D (Dict.Dict c v)` — drop the duplicate `k` from values, reconstruct `k` from `c` when needed via an inverse function. This requires all consumers to change how they extract keys.

Option B (moderate): Keep the current structure but provide documentation that this is an intentional trade-off for ergonomics. The `k` in the tuple gives O(1) access to the rich key type without needing a `c -> k` reverse mapping.

**Risk:** Very high for Option A — touches 108 files, every `Data.Map` consumer. Option B is zero-risk but no improvement.

**Recommendation:** Defer this finding. The overhead is proportional to the number of map entries (one extra pointer per entry), which is less impactful than the O(n^2) and O(n log n) issues above. Revisit after Findings 1 and 2 are fixed and measured.

---

### Finding 4: JS Builder uses O(n^2) string accumulation

**Problem:** `BuilderData.revBuilders` is a `String` that grows by appending (`revBuilders ++ ascii`). Every append copies the entire accumulated output. For JS output of size N, total allocation is O(N^2).

**File:** `compiler/src/Compiler/Generate/JavaScript/Builder.elm` line 1081-1087

**Fix:** Change `revBuilders : String` to `revBuilders : List String` (reversed chunks). All append operations become `newChunk :: revBuilders` (O(1)). At finalization, join with `String.concat (List.reverse revBuilders)` (O(N)).

Functions to modify:
- `BuilderData` type alias (line 1081): change field type
- `addAscii` — change `b.revBuilders ++ ascii` to `ascii :: b.revBuilders`
- `addByteString` — same pattern
- `addName` — same pattern
- `addLine` — same pattern
- `addTrackedByteString` — same pattern
- `currentCol` tracking — currently counts columns by string length; with chunked builders, track column explicitly
- Finalization — wherever `revBuilders` is consumed as a String, change to `String.concat (List.reverse b.revBuilders)`

**Risk:** Medium. Column/line tracking for source maps may depend on string-length calculations of `revBuilders`. Need to verify source map correctness.

**Testing:** Run JS output E2E tests. Compare generated JS output byte-for-byte before/after. Run source map validation if available.

---

## Tier 2: Redundant Data Carried Through AST

### Finding 5: Full `Union` embedded in every `PCtor` pattern

**Problem:** Every `PCtor` in `Can.Pattern` embeds a complete `Can.Union` definition (all constructors, type variables, etc.), even though pattern compilation only needs the constructor name and index.

**File:** `compiler/src/Compiler/AST/Canonical.elm` lines 233-244

**Fix options:**

Option A: Replace the `Union` field with just the information needed: constructor index, total constructor count, and type name.

Option B: Use a reference/key into a shared union table instead of embedding.

**Risk:** Very high — `PCtor` is used throughout canonicalization, optimization, and codegen. Changing its shape requires updating every pattern match on `PCtor` across many modules.

**Recommendation:** Defer. This is a significant architectural change that should be planned as a separate project. The per-pattern overhead is constant (one extra pointer to a shared Union value) and Union values are structurally shared.

---

### Finding 6: Full `Annotation` in every variable reference

**Problem:** `VarForeign`, `VarCtor`, `VarOperator`, and `Binop` in `Can.Expr` embed a full `Can.Annotation` (which includes a `Can.Type` tree). This duplicates type information that's also available in the module's annotation table.

**File:** `compiler/src/Compiler/AST/Canonical.elm` lines 130-139

**Recommendation:** Defer. Same rationale as Finding 5 — pervasive AST shape change.

---

### Finding 7: `Can.Type` on every `TypedOptimized.Expr`

**Problem:** Every variant of `TOpt.Expr` carries a `Can.Type` field. After the typed optimization phase converts types to `MonoType`, these `Can.Type` values are no longer needed, but they remain alive as long as any `TOpt.Expr` reference exists.

**File:** `compiler/src/Compiler/AST/TypedOptimized.elm`

**Recommendation:** Defer. The `Can.Type` is integral to how the typed optimization phase works. Removing it would require a phase-split architecture where a post-typed-opt pass strips types.

---

### Finding 8: `Region` carried through late stages

**Problem:** `A.Region` (source location) is carried on AST nodes into late stages (GlobalOpt, MLIR codegen) where it's only used for error messages that can't actually fire in well-typed programs.

**Recommendation:** Defer. Low impact per node (Region is two ints). Would require a phase-split AST redesign.

---

## Tier 3: No-Op Traversals

### Finding 9: `finalizeLocalGraph` is a complete no-op identity traversal

**Problem:** `finalizeLocalGraph` and its helper `finalizeExpr` traverse the entire `TOpt.LocalGraph` applying `identity` to every type annotation. Every AST node is rebuilt identically — allocating a fresh copy of the entire typed optimization output for zero effect.

**File:** `compiler/src/Compiler/LocalOpt/Typed/Module.elm` lines 116-301

**Fix:** Delete `finalizeLocalGraph`, `finalizeExpr`, `finalizeNode`, `finalizeMain`, `finalizeDef`, `finalizeDestructor`, `finalizeDecider`, `finalizeChoice`. Remove the call on line 103:

```elm
-- BEFORE (line 103):
|> ReportingResult.map (LambdaNorm.normalizeLocalGraph >> finalizeLocalGraph)

-- AFTER:
|> ReportingResult.map LambdaNorm.normalizeLocalGraph
```

**Risk:** Very low. The function literally applies `identity` — its removal cannot change behavior.

**Testing:** `npx elm-test-rs --project build-xhr --fuzz 1` and `cmake --build build --target check`.

---

### Finding 10: `dce` pass is a no-op rebuild

**Problem:** The `dce` function in `MonoInlineSimplify.elm` traverses the entire `MonoExpr` tree and rebuilds every node, but never eliminates anything. The comment says "Most DCE is handled by let simplification / This pass handles any remaining cases" — but the code has no elimination logic; it's a pure identity traversal.

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` lines 2225-2284

**Fix:** Delete the `dce` function. Remove all call sites (search for `dce ` in the file).

**Investigation needed:** Verify that `dce` is only called from within `MonoInlineSimplify.elm` and identify all call sites. If it's called in the fixpoint loop (up to 4 iterations), removing it eliminates 4 full tree rebuilds per function.

**Risk:** Very low. The function is a pure identity traversal — no node is ever eliminated or transformed.

**Testing:** Same as Finding 9.

---

### Finding 11: `collectVarTypes` redundant full walk

**Problem:** In `Compiler/Monomorphize/Closure.elm`, `computeClosureCaptures` performs two full expression walks: first `findFreeLocals` to find free variables, then `collectVarTypes` to look up their types. The type information could be collected during the first walk.

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm`

**Fix:** Merge `collectVarTypes` into `findFreeLocals` so that free variables are collected with their types in a single pass.

**Risk:** Low. Both functions traverse the same AST; merging is mechanical.

**Testing:** Monomorphization E2E tests.

---

### Finding 12: 7+ full traversals in GlobalOpt

**Covered by existing plan:** `globalopt-accidental-complexity-reduction.md`. That plan consolidates multiple GlobalOpt passes into fewer traversals. Defer to that plan.

---

## Tier 4: Serialization and String Overhead

### Finding 13: `toComparableMonoType` creates fresh `List String` on every lookup

**Problem:** Every `Dict` lookup keyed by `MonoType` calls `toComparableMonoType` to serialize the type into a `List String`. This is called on every specialization lookup, creating substantial garbage.

**File:** `compiler/src/Compiler/AST/Monomorphized.elm` line 703-705

**Fix options:**

Option A: Cache the comparable representation alongside the `MonoType` when first computed.

Option B: Use a different Dict key strategy (e.g., assign integer IDs to MonoTypes via an interning table).

**Risk:** Medium. Option A requires threading a cache; Option B requires an interning pass.

**Recommendation:** Implement after Tier 1 fixes. Option B (integer IDs) would give the best performance but is a larger change.

---

### Finding 14: `forceCNumberToInt` unconditionally rebuilds entire type tree

**Problem:** `forceCNumberToInt` traverses the entire `MonoType` tree and rebuilds every node, even when no `CNumber` vars are present (the common case).

**File:** `compiler/src/Compiler/AST/Monomorphized.elm` lines 251-293

**Fix:** Add an early-exit check: if the node is a primitive (`MInt`, `MFloat`, `MBool`, `MChar`, `MString`, `MUnit`), return it directly (the code already does this, but it allocates fresh constructors). For compound nodes, check if children actually changed before allocating a new parent:

```elm
-- For compound nodes, avoid allocation when nothing changed:
MList elemType ->
    let newElem = forceCNumberToInt elemType
    in if newElem == elemType then monoType else MList newElem
```

**Risk:** Low. Reference equality (`==`) in Elm is structural, so the check itself has cost. A simpler approach: add a boolean "has CNumber" flag during monomorphization and skip the call entirely when false.

**Alternative fix:** Add a `hasCNumber : Bool` field to the specialization context and only call `forceCNumberToInt` when `True`.

---

### Finding 15: `sanitizeName` — 14 chained `String.replace` calls

**Problem:** Every MLIR name is passed through 14 `String.replace` calls, each scanning the full string. For names with no special characters (the vast majority), this is 14 wasted full-string scans.

**File:** `compiler/src/Compiler/Generate/MLIR/Names.elm` lines 25-40

**Fix:** Add a fast-path check:

```elm
sanitizeName name =
    if String.all isAlphanumOrUnderscore name then
        name
    else
        name
            |> String.replace "+" "_plus_"
            |> String.replace "-" "_minus_"
            -- ... etc
```

Where `isAlphanumOrUnderscore` checks `Char.isAlphaNum c || c == '_'`.

**Risk:** Very low. The fast path returns the original string unchanged; the slow path is identical to current behavior.

**Testing:** MLIR output comparison.

---

### Finding 16: String-based Union-Find keys in staging

**Problem:** `nodeToKey` builds string keys like `"P:C:elm/core/List:42"` via concatenation for every union-find operation. These strings are created and compared frequently during staging analysis.

**File:** `compiler/src/Compiler/GlobalOpt/Staging/UnionFind.elm` lines 41-47

**Fix:** Replace string keys with integer IDs. Assign each `ProducerId` and `SlotId` a unique integer during graph construction and use `Dict Int` instead of `Dict String`.

**Risk:** Medium. Requires changes to `UnionFind.elm`, `GraphBuilder.elm`, and `Solver.elm`.

**Recommendation:** Implement after Tier 1 fixes. Can be bundled with the GlobalOpt consolidation plan.

---

### Finding 17: `convertUnicodeEscapesToUtf8` is O(n^2)

**Problem:** Character-by-character string building with `acc ++ String.fromChar c` — copies the entire accumulated string on every character.

**File:** `compiler/src/Mlir/Pretty.elm` lines 400-447

**Fix:** Rewrite to build a `List Char` and convert at the end:

```elm
convertUnicodeEscapesToUtf8 s =
    let
        go : List Char -> String -> String
        go revAcc remaining =
            case String.uncons remaining of
                Nothing ->
                    String.fromList (List.reverse revAcc)

                Just ( '\\', rest ) ->
                    case String.uncons rest of
                        Just ( 'u', afterU ) ->
                            let hex4 = String.left 4 afterU in
                            if String.length hex4 == 4 then
                                case parseHex hex4 of
                                    Just codePoint ->
                                        go (Char.fromCode codePoint :: revAcc) (String.dropLeft 4 afterU)
                                    Nothing ->
                                        go ('u' :: '\\' :: revAcc) afterU
                            else
                                go ('u' :: '\\' :: revAcc) afterU
                        Just ( c, afterEscape ) ->
                            go (c :: '\\' :: revAcc) afterEscape
                        Nothing ->
                            String.fromList (List.reverse ('\\' :: revAcc))

                Just ( c, rest ) ->
                    go (c :: revAcc) rest
    in
    go [] s
```

**Risk:** Low. Must preserve exact escape semantics.

**Testing:** MLIR output comparison for programs with unicode string literals.

---

## Tier 5: Data Structure Design

### Finding 18: `EverySet` triple indirection

**Problem:** `EverySet (Dict c a ())` wraps `Data.Map.Dict` which wraps `Dict.Dict c (a, ())`. So each set element has: `EverySet` wrapper → `D` wrapper → Dict node → `(a, ())` tuple → `a`. The `()` is a constant but the tuple is allocated per element.

**File:** `compiler/src/Data/Set.elm` line 54-55

**Fix:** Change `EverySet` to use `Dict.Dict c a` directly (mapping comparable to the rich value, with no unit wrapper):

```elm
type EverySet c a = EverySet (Dict.Dict c a)
```

This eliminates the `()` tuple per element and one layer of wrapping.

**Risk:** Medium. All `EverySet` operations need updating. The `Data.Map.Dict` wrapping provided the `keyComparison` parameter threading, so switching to `Dict.Dict` requires all set operations to accept a comparable-conversion function explicitly (which they already do).

**Recommendation:** Implement after Tier 1. The per-element savings are small but multiply across all set usages.

---

### Finding 19: `Data.Map.intersection` is O(n*m)

**Problem:** `intersection` calls `filter (\k _ -> List.member k keys2)` where `keys2` is a list. `List.member` is O(m) per element, giving O(n*m) total.

**File:** `compiler/src/Data/Map.elm` lines 217-223

**Fix:** Use `Dict.intersect` on the underlying dictionaries:

```elm
intersection _keyComparison (D dict1) (D dict2) =
    D (Dict.intersect dict1 dict2)
```

**Risk:** Low. `Dict.intersect` preserves values from `dict1`, which matches the current behavior.

**Testing:** Unit tests for `Data.Map.intersection`.

---

### Finding 20: IORef arrays never shrunk

**Problem:** Mutable arrays used as IORef pools grow monotonically; entries are never reclaimed even after their referencing scope exits.

**Recommendation:** Defer. This is an inherent limitation of the Elm-in-JS runtime. The pools are bounded by the number of variables created during type solving, which is proportional to program size.

---

### Finding 21: `FreeVars = Dict String Name ()`

**Problem:** `FreeVars` is `Dict String Name ()` — a set encoded as a map-to-unit, incurring one `()` allocation per entry.

**File:** `compiler/src/Compiler/AST/Canonical.elm` line 273

**Fix:** Change to `Data.Set.EverySet String Name` (or if Finding 18 is implemented, the improved `EverySet`).

**Risk:** Low-medium. Need to update all `FreeVars` operations from `Dict.insert/member/...` to `Set.insert/member/...`.

**Recommendation:** Bundle with Finding 18.

---

### Finding 22: `IO.Canonical` redundant tuple

**Problem:** `IO.Canonical` is used pervasively and may carry redundant packaging.

**Recommendation:** Defer — needs investigation to verify the actual overhead.

---

## Tier 6: Pipeline-Level Issues

### Finding 23: `compileTyped` holds all stages live simultaneously

**Covered by existing plans:** `mlir-pipeline-memory-reduction.md` and `compiler-memory-reduction-scope-tightening.md`. Defer to those plans.

---

### Finding 24: Structural equality for fixpoint detection

**Problem:** `exprEqual` in `MonoInlineSimplify.elm` (line 599) uses deep structural comparison to detect fixpoint convergence. For large ASTs, this is expensive.

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` line 599

**Fix options:**

Option A: Use a hash-based change detection — hash the AST before and after each pass, compare hashes.

Option B: Track a "changed" boolean during the rewrite pass and stop iterating when no changes were made.

**Risk:** Option B is simpler and lower-risk. Option A requires implementing a hash function over MonoExpr.

**Recommendation:** Implement Option B alongside the fixpoint loop refactoring.

---

### Finding 25: Per-binding substitution O(bindings * AST)

**Problem:** In `MonoInlineSimplify.elm`, `substituteAll` (line 1048) applies substitutions one binding at a time, each traversing the full AST. For K bindings and an AST of size N, this is O(K*N).

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` line 1048-1055

**Fix:** Collect all substitutions into a `Dict` first, then do a single AST traversal applying all substitutions at once. This reduces O(K*N) to O(N).

**Risk:** Low-medium. Must ensure substitution ordering semantics are preserved (no substitution should apply to the result of another substitution in the same batch).

---

## Additional Findings (from string/text investigation)

### Finding 26: `indentPad` allocates fresh string on every MLIR op

**Problem:** `indentPad n = String.repeat (2 * n) " "` is called once per MLIR op. The indent levels are always 1, 2, or 3.

**File:** `compiler/src/Mlir/Pretty.elm` lines 334-335

**Fix:** Memoize with a case statement:
```elm
indentPad n =
    case n of
        0 -> ""
        1 -> "  "
        2 -> "    "
        3 -> "      "
        _ -> String.repeat (2 * n) " "
```

**Risk:** None.

---

### Finding 27: `specIdToFuncName` recomputed on every reference

**Problem:** The same `specId` may be referenced multiple times during codegen, but `specIdToFuncName` recomputes the mangled name each time (including calling `sanitizeName` with its 14 `String.replace` calls).

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` lines 250-259

**Fix:** Cache computed names in the `Context` record. On first lookup, compute and store; on subsequent lookups, return cached value.

**Risk:** Low. Requires adding a `Dict SpecId String` to Context.

---

## Implementation Order

The fixes are ordered by impact/effort ratio (best bang-for-buck first):

### Phase 1: Quick wins (mechanical, low risk, high impact)

| Order | Finding | Effort | Impact |
|-------|---------|--------|--------|
| 1a | F9: Delete `finalizeLocalGraph` | 30 min | Eliminates 100% redundant AST copy |
| 1b | F10: Delete `dce` no-op pass | 30 min | Eliminates 4x full tree rebuild per function |
| 1c | F26: Memoize `indentPad` | 5 min | Eliminates ~1000 `String.repeat` calls |
| 1d | F15: Fast-path `sanitizeName` | 15 min | Eliminates 14 * N string scans for common case |

### Phase 2: O(n^2) list fixes (mechanical, medium effort, high impact)

| Order | Finding | Effort | Impact |
|-------|---------|--------|--------|
| 2a | F1: Fix `MonoTraverse.traverseList` | 15 min | Fixes O(n^2) for all GlobalOpt consumers |
| 2b | F1: Fix `Names.traverse` (Typed + Erased) | 15 min | Fixes O(n^2) for all LocalOpt consumers |
| 2c | F1: Fix 15 sites in `MonoInlineSimplify` | 1 hr | Fixes O(n^2) in inliner |
| 2d | F1: Fix 13 `accOps ++` sites in MLIR codegen | 1 hr | Fixes O(n^2) in code generation |

### Phase 3: Data structure fixes (moderate effort, high impact)

| Order | Finding | Effort | Impact |
|-------|---------|--------|--------|
| 3a | F2: Fix `Data.Map.foldl`/`foldr` | 1 hr + audit | Eliminates sort + materialize for 104 call sites |
| 3b | F19: Fix `Data.Map.intersection` | 15 min | O(n*m) → O(n log m) |
| 3c | F4: Change JS Builder to `List String` | 2 hr | O(n^2) → O(n) for JS output |

### Phase 4: String/serialization fixes (moderate effort, medium impact)

| Order | Finding | Effort | Impact |
|-------|---------|--------|--------|
| 4a | F17: Fix `convertUnicodeEscapesToUtf8` | 30 min | O(n^2) → O(n) for unicode strings |
| 4b | F27: Cache `specIdToFuncName` in Context | 30 min | Eliminates redundant name mangling |
| 4c | F14: Skip `forceCNumberToInt` when unnecessary | 30 min | Eliminates unconditional tree copy |

### Phase 5: Larger refactors (high effort, defer until measured)

| Order | Finding | Effort | Impact |
|-------|---------|--------|--------|
| 5a | F11: Merge `collectVarTypes` into `findFreeLocals` | 1 hr | Eliminates one full expression walk |
| 5b | F24: Change fixpoint detection to "changed" flag | 2 hr | Eliminates deep structural comparison |
| 5c | F25: Batch substitutions into single pass | 2 hr | O(K*N) → O(N) |
| 5d | F16: Integer keys for Union-Find | 3 hr | Eliminates string key construction |
| 5e | F13: Integer IDs for MonoType dict keys | 4 hr | Eliminates type serialization per lookup |

### Phase 6: Deferred (high risk or covered by other plans)

| Finding | Reason |
|---------|--------|
| F3: Data.Map dual keys | Very high risk (108 files), moderate per-element savings |
| F5-F8: AST shape changes | Pervasive, requires architectural redesign |
| F12: GlobalOpt traversals | Covered by `globalopt-accidental-complexity-reduction.md` |
| F18, F21: EverySet / FreeVars | Bundle together as a separate data-structure plan |
| F20: IORef pool shrinking | Runtime limitation |
| F22: IO.Canonical tuple | Needs investigation |
| F23: Pipeline scoping | Covered by `mlir-pipeline-memory-reduction.md` |

---

## Questions and Open Issues

1. **Finding 2 (Data.Map.foldl order):** Do any of the 104 call sites depend on key-sorted iteration order? If yes, those sites need to keep the sort-based implementation or use `toList` explicitly. Need to audit before implementing.

2. **Finding 4 (JS Builder):** The `currentCol` tracking in `BuilderData` currently relies on string length arithmetic on `revBuilders`. With a `List String` representation, how should column tracking work? Options: (a) track column explicitly with arithmetic on each appended chunk, (b) compute it only at finalization.

3. **Finding 10 (dce):** Need to verify all call sites of `dce` within `MonoInlineSimplify.elm`. Is it called in the fixpoint loop? If the fixpoint loop calls `rewrite >> dce >> exprEqual`, removing `dce` changes the fixpoint input and could theoretically affect convergence (even though `dce` is identity, the fixpoint comparison addresses would differ). Need to check whether `exprEqual` is structural or reference-based.

4. **Testing strategy:** Should we measure peak RSS before and after each phase? This would give concrete data on impact. Proposed: use `/usr/bin/time -v` on the self-compilation bootstrap step.

5. **Ordering within Phase 2:** The `MonoTraverse.traverseList` fix (2a) is the highest-leverage single fix since all GlobalOpt consumers go through it. Should it be tested in isolation first?
