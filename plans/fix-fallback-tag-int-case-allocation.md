# Plan: Fix O(maxTag) allocation in `computeFallbackTag` for int/char cases

## Summary

Compiling any program whose `case` matches **large integer (or high char-code) literals** hangs the
back-end at 100% CPU with unbounded RAM growth and eventually OOMs. Root cause (fully traced):
`Compiler/Generate/MLIR/Patterns.elm:computeFallbackTag` finds the case's fallback tag with
`List.range 0 (maxTag + 1) |> List.filter … |> List.head`, which is **O(maxTag) in time and
allocation**. For `int` cases `testToTagInt (Test.IsInt i) = i` returns the literal value, so
`maxTag` is the largest matched literal. `justgook/elm-image`'s `Image/Internal/PNG.elm` matches PNG
chunk types as 4-byte packed ints (`IHDR`=1229472850 … `tRNS`=**1951551059**), so
`List.range 0 1951551060` tries to allocate a ~1.95-billion-element list (~47 GB) → OOM.

Fix: replace the `0..maxTag` enumeration with a **sort-and-scan** that computes the *same value*
(smallest non-negative integer not in `usedTags`) in **O(n log n)** in the number of edges,
independent of the tag magnitude.

## Design Decisions

| Decision | Choice |
|----------|--------|
| Algorithm | Sort `usedTags`, scan for the first gap from 0 — the smallest non-negative tag not in the set |
| Behavioural equivalence | Result is identical to the current code for every input (see proof below); no codegen change downstream |
| Branch on case kind? | **No.** Sort-and-scan is uniformly correct for ctor *and* int/chr; avoids threading `caseKind` into `computeFallbackTag` |
| Keep Bool/Cons/Nil fast paths | Yes — the existing 2-way special cases stay (they return the *complement* ctor tag, not "first gap") |
| Scope | Single function body in `Patterns.elm`; both call sites (`Expr.elm`, `TailRec.elm`) are unaffected |

## Why sort-and-scan is exactly equivalent (not just "close")

Current code computes: the smallest value in `[0 .. maxTag+1]` not in `usedTags`, falling back to
`maxTag+1`. Since `usedTags ⊆ [minTag .. maxTag]`, that is precisely **the smallest non-negative
integer not in `usedTags`** (negatives are skipped because the range starts at 0; if `0..maxTag` are
all used, the answer is `maxTag+1`). Sort-and-scan computes the same quantity directly:

- ctor `{0,2}` → `1` (unchanged); ctor `{0,1}` → `2` (unchanged).
- int `{1229472850, 1347179589, 1951551059, …}` → `0` (smallest non-negative not used) — a valid
  distinct sentinel for the fallback region, in **microseconds** instead of a 47 GB allocation.

The fallback tag only has to be **distinct from the edge tags** (it labels the catch-all region in
`edgeTags ++ [fallbackTag]` passed to `Ops.ecoCase`); `0` satisfies that for the PNG case and every
int/char case where `0` isn't a matched literal, and the scan naturally yields the next gap when it is.

## Steps

### Step 1: Replace the `_` branch of `computeFallbackTag`

**File:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm` (the `_ ->` branch, ~lines 1084-1097)

Replace:
```elm
        _ ->
            let
                usedTags = List.map testToTagInt edgeTests
                maxTag   = List.maximum usedTags |> Maybe.withDefault 0
            in
            List.range 0 (maxTag + 1)
                |> List.filter (\t -> not (List.member t usedTags))
                |> List.head
                |> Maybe.withDefault (maxTag + 1)
```
with a sort-and-scan:
```elm
        _ ->
            -- Smallest non-negative tag not among the edges. Computed by sorting
            -- the (few) edge tags and scanning for the first gap from 0, so the
            -- cost is O(n log n) in the EDGE COUNT, never O(maxTag). The old
            -- `List.range 0 (maxTag+1)` allocated a list proportional to the
            -- largest matched literal, which OOMs for int cases over large
            -- literals (e.g. PNG chunk-type codes ~1.95e9 in justgook/elm-image).
            firstUnusedTag 0 (List.sort (List.map testToTagInt edgeTests))
```

### Step 2: Add the `firstUnusedTag` helper

**File:** same module (next to `computeFallbackTag`)
```elm
{-| Smallest non-negative Int not present in the (ascending-sorted) list. -}
firstUnusedTag : Int -> List Int -> Int
firstUnusedTag candidate sortedTags =
    case sortedTags of
        [] ->
            candidate

        t :: rest ->
            if t < candidate then
                firstUnusedTag candidate rest        -- below/duplicate: skip

            else if t == candidate then
                firstUnusedTag (candidate + 1) rest  -- candidate taken: advance

            else
                candidate                            -- t > candidate: gap found
```
Tail-recursive; `n` = number of edges (small). No dependence on tag magnitude.

### Step 3: (No change at call sites)

`Expr.elm:generateFanOutGeneralWithJumps` (~5459) and `TailRec.elm` (~758) call
`Patterns.computeFallbackTag edgeTests` and use the result identically. Downstream
`edgeTags ++ [fallbackTag]` → `Ops.ecoCase`/`Ops.ecoCaseString` is unchanged because the returned
value is identical to before.

## Testing / Verification

1. **Targeted unit test** (new) under `compiler/tests/TestLogic/Generate/MLIR/` (e.g.
   `FallbackTagTest.elm`): assert `computeFallbackTag` returns the same values as before on small
   ctor inputs (`[IsBool True] → 0`, ctor `{0,2} → 1`, `{0,1} → 2`) **and** returns promptly for a
   large-int input (`[IsInt 1229472850, IsInt 1951551059] → 0`) — this both pins behaviour and is a
   regression guard against re-introducing an O(maxTag) loop. (No existing test references this
   function today.)
2. **The original repro** (disk-safe: `ulimit -c 0`): `eco make projects/eco-test/src/Hello.elm
   --output=test` now reaches and completes the MLIR phase for `Image.decode` instead of OOMing in
   `List.range`. Validate via the JS fast-loop (`eco-boot.js --output=*.mlir`) first (seconds), then
   the native binary.
3. **Regression:** `cmake --build build --target elm-tests` (expect 0 failures; the non-zero exit is
   the pre-existing `Test.skip` "INCOMPLETE" artifact) and `cmake --build build --target full`
   (JIT E2E, expect PASSED).
4. Confirm produced MLIR for a small int-case is byte-identical before/after on an input with small
   tags (equivalence sanity check).

## Risks / Caveats

- **Behavioural equivalence is the safety property** — Step 1 changes *cost*, not *result* (proof
  above). If any downstream code depended on the fallback tag being specifically `maxTag+1` for int
  cases (it does not — it only needs distinctness), that would surface in the E2E suite.
- **Char cases** (`Test.IsChr`, code points up to 0x10FFFF, or larger via `\u{…}` mis-decode) had the
  same latent O(maxTag) cost; the same fix covers them.
- **`str` cases** never reach this branch (handled by the `caseKind == "str"` path in
  `generateFanOutGeneralWithJumps`), so they're unaffected.
- Negative int literals: `usedTags` may contain negatives; the scan skips `t < candidate`, so the
  result stays "smallest non-negative unused", matching the old `List.range 0 …` which also ignored
  negatives.

## Out of scope (follow-ups)

- Whether `int` cases should carry a fallback *tag* at all (the runtime dispatch for `caseKind=="int"`
  uses i64 comparison + a default region; the tag value is a label). Simplifying that is a separate,
  larger change; this plan keeps the contract intact.
- Auditing other back-end sites for `List.range`/enumeration keyed on value-derived integers.
