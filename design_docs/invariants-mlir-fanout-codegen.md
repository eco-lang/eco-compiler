# Invariant Investigation: MLIR `generateFanOutGeneral` and `findBoolBranches`

## Issue Summary

The MLIR code generation for pattern match FanOut operations relies on upstream invariants about the structure of decision trees. Two specific areas need investigation:

1. **`generateFanOutGeneral`**: Generates `eco.case` operations with a computed fallback tag, assuming the fallback decider represents a valid alternative.

2. **`findBoolBranches`**: Extracts True/False branches from edges, using `fallback` as a default when a branch is missing.

Both functions could generate incorrect code if their input invariants are violated.

## Locations

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### `findBoolBranches` (lines 4154-4172)

```elm
findBoolBranches : List ( DT.Test, Mono.Decider Mono.MonoChoice )
                -> Mono.Decider Mono.MonoChoice
                -> ( Mono.Decider Mono.MonoChoice, Mono.Decider Mono.MonoChoice )
findBoolBranches edges fallback =
    let
        findBranch target =
            edges
                |> List.filter
                    (\( test, _ ) ->
                        case test of
                            DT.IsBool b ->
                                b == target

                            _ ->
                                False
                    )
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault fallback
    in
    ( findBranch True, findBranch False )
```

### `generateFanOutGeneral` (lines 4178-4239)

```elm
generateFanOutGeneral ctx root path edges fallback resultTy =
    let
        -- Collect tags from edges
        edgeTags =
            List.map (\( test, _ ) -> testToTagInt test) edges

        -- Compute the fallback tag (for the fallback region)
        edgeTests =
            List.map Tuple.first edges

        fallbackTag =
            computeFallbackTag edgeTests

        -- All tags including the fallback
        tags =
            edgeTags ++ [ fallbackTag ]

        -- Generate regions for each edge + fallback
        ...
```

## Invariant Analysis

### For `findBoolBranches`

**Expected Input**:
- When called for a Bool FanOut, `edges` should contain `IsBool` tests.
- Either:
  1. Both `IsBool True` and `IsBool False` are present (exhaustive), OR
  2. One is present and `fallback` represents the other case.

**Invariant Chain**:
1. Decision tree compilation marks Bool patterns as complete when both True and False are present (`isComplete` returns `True` for `List.length tests == 2`).
2. If only one branch is present, there must be an explicit fallback.
3. The fallback represents the missing case.

**Risk Analysis**:

| Scenario | edges Contains | fallback | Behavior | Correct? |
|----------|---------------|----------|----------|----------|
| Both branches | `[True, False]` | Any | Returns both from edges | YES |
| True only | `[True]` | False case | True from edge, False from fallback | YES |
| False only | `[False]` | True case | True from fallback, False from edge | YES |
| Neither | `[]` | ??? | Both from fallback | **WRONG** |

**Risk**: If `edges` is empty (no Bool tests), both branches become `fallback`, which would be incorrect.

### For `generateFanOutGeneral`

**Expected Input**:
- `edges` contains tests for specific constructor tags.
- `fallback` handles all other cases (could be empty if edges are exhaustive).

**Invariant Chain**:
1. The Mono decider mirrors the structure from `treeToDecider`.
2. When `fallback` exists, it represents a valid default case.
3. `computeFallbackTag` generates a tag value that doesn't conflict with edge tags.

**Risk Analysis**:

The generated `eco.case` structure:
```
eco.case %scrutinee [tag1, tag2, ..., fallbackTag] {
    // region for tag1
}, {
    // region for tag2
}, ..., {
    // fallback region
}
```

If `computeFallbackTag` returns a tag that's already in `edgeTags`, we'd have duplicate tags in the case, which could cause undefined behavior.

## Code Path Tracing

### Entry Point: `generateDecider`

```elm
generateDecider : Context -> Name.Name -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateDecider ctx root decider resultTy =
    case decider of
        ...
        Mono.FanOut path tests fallback ->
            generateFanOut ctx root path tests fallback resultTy
```

### `generateFanOut` Dispatch

```elm
generateFanOut ctx root path edges fallback resultTy =
    if isBoolFanOut edges then
        generateBoolFanOut ctx root path edges fallback resultTy
    else
        generateFanOutGeneral ctx root path edges fallback resultTy
```

### `isBoolFanOut` Check

```elm
isBoolFanOut : List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Bool
isBoolFanOut edges =
    case edges of
        [] ->
            False                           -- Empty edges → not Bool → general path

        ( test, _ ) :: _ ->
            case test of
                DT.IsBool _ ->
                    True                    -- Has IsBool → Bool path

                _ ->
                    False                   -- Other test → general path
```

**Key Observation**: If `edges` is empty, `isBoolFanOut` returns `False`, so it goes to `generateFanOutGeneral`, not `generateBoolFanOut`. This means `findBoolBranches` won't be called with empty edges through normal paths.

## Safety Assessment

### `findBoolBranches` Safety

**Safe** because:
1. `isBoolFanOut` checks that at least one edge exists and it's `IsBool`.
2. If edges is empty, `isBoolFanOut` returns `False`, so `findBoolBranches` isn't called.
3. When `findBoolBranches` IS called, at least one Bool branch is guaranteed.

**Remaining Risk**: If only one Bool test exists and `fallback` isn't semantically correct for the missing case, wrong code is generated. However, this would be an upstream bug (decision tree construction).

### `generateFanOutGeneral` Safety

**Safe** assuming:
1. `computeFallbackTag` generates unique tags.
2. The Mono decider's `fallback` represents valid semantics.

**Risk**: Need to verify `computeFallbackTag` implementation.

## Investigation: `computeFallbackTag`

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm:3834-3862`

```elm
{-| Compute the fallback tag for a fan-out based on the edge tests.
For two-way branches (Bool, Cons/Nil), this computes the "other" tag.
For N-way branches (custom types), this finds the first missing tag.
-}
computeFallbackTag : List DT.Test -> Int
computeFallbackTag edgeTests =
    case edgeTests of
        [ DT.IsBool True ] ->
            0                                   -- True=1, so fallback is False=0

        [ DT.IsBool False ] ->
            1                                   -- False=0, so fallback is True=1

        [ DT.IsCons ] ->
            0                                   -- Cons=1, so fallback is Nil=0

        [ DT.IsNil ] ->
            1                                   -- Nil=0, so fallback is Cons=1

        _ ->
            -- For custom types with multiple edges, find the first unused tag
            let
                usedTags =
                    List.map testToTagInt edgeTests

                maxTag =
                    List.maximum usedTags |> Maybe.withDefault 0
            in
            -- Find first unused tag from 0 to maxTag+1
            List.range 0 (maxTag + 1)
                |> List.filter (\t -> not (List.member t usedTags))
                |> List.head
                |> Maybe.withDefault (maxTag + 1)
```

### Analysis

**Two-way branches (Bool, Cons/Nil)**:
- Explicitly handles single-edge cases to compute the "other" tag.
- Safe: Returns the complement tag.

**Multi-way branches (Custom Types)**:
- Finds the first unused tag in range `[0, maxTag+1]`.
- **Safe**: Always returns a tag not in `usedTags`.
- The `Maybe.withDefault (maxTag + 1)` handles the edge case where all tags `[0..maxTag]` are used.

**Risk Assessment**: The implementation is **SOUND**. It guarantees a unique fallback tag.

## Recommended Guardrails

### Option 1: Defensive Checks in `findBoolBranches`

```elm
findBoolBranches edges fallback =
    let
        hasTrue =
            List.any
                (\( test, _ ) ->
                    case test of
                        DT.IsBool True ->
                            True

                        _ ->
                            False
                )
                edges

        hasFalse =
            List.any
                (\( test, _ ) ->
                    case test of
                        DT.IsBool False ->
                            True

                        _ ->
                            False
                )
                edges
    in
    if not hasTrue && not hasFalse then
        Utils.Crash.crash "findBoolBranches: called with no IsBool tests"

    else
        let
            findBranch target =
                edges
                    |> List.filter ...
                    |> List.head
                    |> Maybe.map Tuple.second
                    |> Maybe.withDefault fallback
        in
        ( findBranch True, findBranch False )
```

### Option 2: Defensive Check in `generateBoolFanOut`

```elm
generateBoolFanOut ctx root path edges fallback resultTy =
    let
        -- Verify we have at least one Bool test
        _ =
            if List.isEmpty edges then
                Utils.Crash.crash "generateBoolFanOut: empty edges list"
            else
                ()

        ( trueBranch, falseBranch ) =
            findBoolBranches edges fallback
        ...
```

### Option 3: Verify `computeFallbackTag` Uniqueness

In `generateFanOutGeneral`:

```elm
generateFanOutGeneral ctx root path edges fallback resultTy =
    let
        edgeTags =
            List.map (\( test, _ ) -> testToTagInt test) edges

        fallbackTag =
            computeFallbackTag (List.map Tuple.first edges)

        -- SANITY CHECK: fallback tag must not be in edge tags
        _ =
            if List.member fallbackTag edgeTags then
                Utils.Crash.crash
                    ("generateFanOutGeneral: fallbackTag " ++ String.fromInt fallbackTag
                     ++ " conflicts with edgeTags " ++ Debug.toString edgeTags)
            else
                ()

        tags =
            edgeTags ++ [ fallbackTag ]
        ...
```

### Option 4: Validate `isBoolFanOut` Coverage

```elm
isBoolFanOut : List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Bool
isBoolFanOut edges =
    case edges of
        [] ->
            -- Edge case: empty edges should not happen in well-formed FanOut
            Utils.Crash.crash "isBoolFanOut: empty edges list"

        ( test, _ ) :: _ ->
            case test of
                DT.IsBool _ ->
                    True

                _ ->
                    False
```

However, this might be too aggressive if there are legitimate cases with empty edges.

## Findings Summary

| Function | Current Safety | Risk Level | Recommendation |
|----------|---------------|------------|----------------|
| `findBoolBranches` | Safe (guarded by `isBoolFanOut`) | Low | Add internal assert for defense |
| `generateBoolFanOut` | Safe | Low | Already protected by `isBoolFanOut` |
| `generateFanOutGeneral` | Likely safe | Low-Medium | Verify `computeFallbackTag` + add uniqueness check |
| `isBoolFanOut` | Safe | Very Low | Consider crash on empty (if impossible) |

## Conclusion

The MLIR code generation is **SAFE** based on completed investigation:

1. **`isBoolFanOut` dispatch**: Prevents `findBoolBranches` from being called with empty edges.
2. **`computeFallbackTag`**: Correctly generates unique tags in all cases.
3. **Invariant chain**: Decision tree construction → Mono decider → MLIR codegen is sound.

**Priority**: Low - All investigated functions are correct. Defensive assertions would add robustness but aren't strictly necessary.

**Recommended Actions**:
1. Add `Utils.Crash.crash` for impossible states (empty edges in Bool FanOut) as defense-in-depth
2. Document the invariant contract between decision tree construction and MLIR codegen
3. Consider adding uniqueness assertion in `generateFanOutGeneral` to catch future bugs
