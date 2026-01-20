# Fix String Case Tag Handling

## Problem

For multi-way string pattern matches, the MLIR codegen currently produces non-unique tags:

- `case_kind = "str"` (correct)
- Scrutinee type `!eco.value` (correct for strings)
- Tags computed via `Patterns.testToTagInt`, which returns `0` for every `DT.IsStr` test:

```elm
testToTagInt : DT.Test -> Int
testToTagInt test =
    case test of
        ...
        DT.IsStr _ ->
            0
```

`generateFanOutGeneral` then uses these tags plus a computed fallback tag:

```elm
edgeTags   = List.map (\( test, _ ) -> Patterns.testToTagInt test) edges
fallbackTag = Patterns.computeFallbackTag edgeTests
tags        = edgeTags ++ [ fallbackTag ]
```

For N string branches, this produces tags like `[0, 0, 0, ..., 1]`, which are not injective. Downstream lowering cannot distinguish which region corresponds to which string literal, and will effectively treat them all as "the same tag", so the default/first branch is always selected.

**Goal:** Tags for `case_kind="str"` must be unique per branch, while leaving constructor/int/chr cases unchanged.

---

## Target Semantics for String Case

For `eco.case` with `case_kind="str"`:

- **Scrutinee:** `!eco.value` representing an Elm string (boxed)
- **Alternatives:** one per pattern branch plus one fallback
- **Tags** behave as opaque indices:
  - For a `FanOut` with `k` explicit string branches:
    - `tags[0..k-1] = [0, 1, ..., k-1]` (one unique tag per branch)
    - `tags[k] = k` for the fallback/default branch

The actual string matching is done by the EcoControlFlow/EcoToLLVM passes using:
- The scrutinee string
- The list of literal strings in the decision tree (they don't come from `tags`)
- `tags` only index *which* region to jump to when a given literal matches

**Design principle:** For `case_kind == "str"`, ignore `testToTagInt` and synthesize tags purely by branch index; for all other `case_kind`s, keep existing behavior.

---

## Code Changes

### Step 1: Change `generateFanOutGeneral` to special-case string cases

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Locate `generateFanOutGeneral` and replace the "Collect tags" block with a `caseKind`-aware branch:

```elm
        -- Collect tags from edges.
        --
        -- For most case kinds, tags are derived from the DT.Test (ctor index,
        -- int literal, char code, etc.) so the runtime can use them directly.
        --
        -- For string cases (case_kind = "str"), tags are *indices*:
        --   - edgeTags = [0..k-1] for k edges
        --   - fallbackTag = k
        -- The Eco control-flow/LLVM lowering uses these as opaque branch IDs
        -- and performs string equality checks against the literal patterns.
        ( edgeTags, fallbackTag ) =
            case caseKind of
                "str" ->
                    let
                        edgeCount : Int
                        edgeCount =
                            List.length edgeTests

                        -- One unique tag per explicit edge: 0..edgeCount-1
                        stringEdgeTags : List Int
                        stringEdgeTags =
                            List.range 0 (edgeCount - 1)

                        -- Fallback tag is a distinct sentinel: edgeCount
                        stringFallbackTag : Int
                        stringFallbackTag =
                            edgeCount
                    in
                    ( stringEdgeTags, stringFallbackTag )

                _ ->
                    let
                        computedEdgeTags : List Int
                        computedEdgeTags =
                            List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

                        computedFallbackTag : Int
                        computedFallbackTag =
                            Patterns.computeFallbackTag edgeTests
                    in
                    ( computedEdgeTags, computedFallbackTag )

        -- All tags including the fallback
        tags =
            edgeTags ++ [ fallbackTag ]
```

Leave the rest of `generateFanOutGeneral` unchanged (region generation, fallback region, and the final `Ops.ecoCase` call).

**Why this works:**
- For non-string cases (`"ctor"`, `"int"`, `"chr"`, `"bool"` legacy), behavior is unchanged: tags still come from `testToTagInt` and `computeFallbackTag`
- For string cases (`"str"`):
  - Every explicit `IsStr` edge gets its own unique tag `0..k-1`
  - Fallback gets tag `k`, which is guaranteed not to collide
  - Lowering and runtime can now distinguish which region to choose for each literal

### Step 2: Clarify `testToTagInt`'s role for strings

**File:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm`

Update the comment on `DT.IsStr` inside `testToTagInt` to document its now-limited role:

```elm
        DT.IsStr _ ->
            -- String cases use per-branch indices for tags (see generateFanOutGeneral),
            -- so this value is only used in non-string contexts (e.g. completeness checks).
            0
```

This makes it clear that string tags for `eco.case` are *not* derived here any more.

### Step 3 (Optional): Document string tag semantics on the dialect op

**File:** `runtime/src/codegen/eco/Ops.td`

Extend the `case_kind="str"` bullet in the `Eco_CaseOp` description:

```td
    - `!eco.value` + `case_kind="str"`: String pattern matching.
      For this kind, the `tags` array contains opaque branch indices
      (0..N for N explicit patterns plus fallback); actual matching is done
      by comparing the scrutinee string to the literal patterns.
```

No semantic change; this just encodes the design decision in dialect documentation.

---

## Validation

1. **Edit `Expr.elm`** as in Step 1
2. **Edit `Patterns.elm`** as in Step 2
3. **(Optional) Edit `Ops.td`** as in Step 3

4. **Rebuild Elm compiler + runtime:**
   - Run Elm compiler tests (`elm-test` for codegen invariants)
   - Run the E2E suite, with particular focus on:
     - `CaseStringTest` (which was failing with "expected 2, got 1")
     - Any other tests that exercise `case` on strings

5. **Manual sanity-check of generated MLIR for a representative string case:**

   For Elm:
   ```elm
   which : String -> Int
   which s =
     case s of
       "foo" -> 1
       "bar" -> 2
       _     -> 3
   ```

   After the change, the `eco.case` op should look like:
   ```mlir
   eco.case %s [0, 1, 2] { case_kind = "str", ... } {
       // tag 0 -> "foo" branch
       eco.return %one : !eco.value
   }, {
       // tag 1 -> "bar" branch
       eco.return %two : !eco.value
   }, {
       // tag 2 -> fallback branch
       eco.return %three : !eco.value
   }
   ```

   Previously, tags would have looked like `[0, 0, 1]`.

6. **(Future work) Add invariant test:**
   A CodeGen invariant test that inspects `eco.case` with `case_kind="str"` and asserts:
   - All tags for alternatives except the last are distinct
   - The last tag is greater than any earlier tag

   Would live in `compiler/tests/Compiler/Generate/CodeGen/CaseStringTagsTest.elm`.

---

## Summary

This design:
- Fixes the root cause for wrong dispatch in string `case` by making `tags` unique per branch for `case_kind="str"`
- Keeps all non-string case behavior unchanged
- Aligns dialect documentation with implementation

With just the `Expr.elm` change you get the functional fix; the `Patterns.elm` and `Ops.td` edits make the design explicit and maintainable.
