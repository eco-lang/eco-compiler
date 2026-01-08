# Invariant Investigation: `treeToDecider` Last-Edge Fallback Handling

## Issue Summary

The `treeToDecider` function in the Elm decision tree optimizer treats the **last edge** of a `DT.Decision` with no explicit fallback as the implicit fallback. This relies on the invariant that when `DT.Decision path edges Nothing` is constructed, the `edges` list forms an **exhaustive** set of tests. If this invariant is violated, code will silently take the wrong branch at runtime.

## Location

**File**: `compiler/src/Compiler/Optimize/Erased/Case.elm:103-111`

```elm
-- many options
DT.Decision path edges Nothing ->
    let
        ( necessaryTests, fallback ) =
            ( Prelude.init edges, Tuple.second (Prelude.last edges) )
    in
    Opt.FanOut
        path
        (List.map (Tuple.mapSecond treeToDecider) necessaryTests)
        (treeToDecider fallback)
```

## Invariant Chain

The correctness of this code depends on invariants maintained upstream:

### 1. Pattern Exhaustiveness Check

**File**: `compiler/src/Compiler/Reporting/Error/PatternMatches.elm` (or similar)

The pattern checker must reject non-exhaustive case expressions before decision tree compilation.

### 2. Decision Tree Construction

**File**: `compiler/src/Compiler/Optimize/Erased/DecisionTree.elm`

The `isComplete` function (lines 185-210) determines when edges are exhaustive:

```elm
isComplete : List Test -> Bool
isComplete tests =
    case Prelude.head tests of
        IsCtor _ _ _ numAlts _ ->
            numAlts == List.length tests      -- All constructors covered

        IsCons ->
            List.length tests == 2            -- Cons and Nil covered

        IsNil ->
            List.length tests == 2            -- Same as above

        IsTuple ->
            True                              -- Tuples are single-case

        IsInt _ ->
            False                             -- Integers are infinite

        IsChr _ ->
            False                             -- Characters are large domain

        IsStr _ ->
            False                             -- Strings are infinite

        IsBool _ ->
            List.length tests == 2            -- True and False covered
```

The `gatherEdges` function (lines 330-349) uses this:

```elm
gatherEdges : List Branch -> Path -> ( List ( Test, List Branch ), List Branch )
gatherEdges branches path =
    let
        relevantTests = testsAtPath path branches
        allEdges = List.map (edgesFor path branches) relevantTests

        fallbacks =
            if isComplete relevantTests then
                []                           -- No fallback needed - exhaustive!
            else
                List.filter (isIrrelevantTo path) branches
    in
    ( allEdges, fallbacks )
```

### 3. Decision Tree Assembly

**File**: `compiler/src/Compiler/Optimize/Erased/DecisionTree.elm:171-182`

```elm
case ( decisionEdges, fallback ) of
    ( [ ( _, decisionTree ) ], [] ) ->
        decisionTree

    ( _, [] ) ->
        Decision path decisionEdges Nothing   -- ← This is the case

    ( [], _ :: _ ) ->
        toDecisionTree fallback

    _ ->
        Decision path decisionEdges (Just (toDecisionTree fallback))
```

When `fallback` is empty (`[]`) AND there are multiple edges, we get `Decision path edges Nothing`.

## Analysis: Is the Invariant Sound?

### For `IsCtor` (Custom Types)

**Safe** when:
- The pattern checker verified all constructors are handled
- `isComplete` correctly checks `numAlts == List.length tests`

**Risk**:
- If `numAlts` is wrong (e.g., due to faulty union info), `isComplete` returns `True` incorrectly.

### For `IsBool`

**Safe** when:
- Both `True` and `False` are matched
- `isComplete` checks `List.length tests == 2`

**Risk**:
- If only one branch is matched but `isComplete` is called with incorrect `tests` list.

### For `IsCons`/`IsNil` (Lists)

**Safe** when:
- Both `[]` and `(x :: xs)` patterns are present
- `isComplete` checks `List.length tests == 2`

**Risk**:
- Same as Bool - relies on correct test collection.

### For `IsInt`/`IsStr`/`IsChr`

**Always incomplete** - these return `False` from `isComplete`, so they should always have an explicit fallback. If they don't, it's a bug upstream.

## Examination of `treeToDecider` Behavior

When `DT.Decision path edges Nothing`:

1. **edges is guaranteed non-empty** due to earlier pattern match:
   ```elm
   DT.Decision _ [] Nothing ->
       crash "compiler bug, somehow created an empty decision tree"
   ```

2. **Last edge becomes fallback**:
   ```elm
   ( necessaryTests, fallback ) =
       ( Prelude.init edges, Tuple.second (Prelude.last edges) )
   ```

This means if `edges = [(test1, tree1), (test2, tree2), (test3, tree3)]`:
- `necessaryTests = [(test1, tree1), (test2, tree2)]`
- `fallback = tree3`

The generated `FanOut` will:
- Test `test1`, if true → `tree1`
- Test `test2`, if true → `tree2`
- Otherwise → `tree3` (fallback)

This is **semantically correct** only if `test3` is guaranteed to match when `test1` and `test2` fail.

## Risk Scenarios

### Scenario 1: Missing Constructor

If a custom type has 3 constructors `A | B | C` but only `A` and `B` are matched:

```elm
case x of
    A -> ...
    B -> ...
    -- C not handled!
```

**Expected**: Pattern checker rejects this.
**If pattern checker fails**: `isComplete` sees 2 tests but needs 3, returns `False`, creates explicit fallback. **Still safe** (caught at next level).

### Scenario 2: Incorrect `numAlts` in Union Info

If the union info says `numAlts = 2` but there are actually 3 constructors:

**Expected**: Never happens (type-checking ensures union info is correct).
**If it happens**: `isComplete` returns `True` for 2 tests, no explicit fallback created. `treeToDecider` uses last edge as fallback. Constructor `C` would incorrectly match constructor `B`'s branch.

### Scenario 3: Integer/String Patterns

```elm
case n of
    1 -> "one"
    2 -> "two"
    3 -> "three"
```

**Expected**: `isComplete` returns `False` (integers are infinite), explicit fallback created.
**Actual**: Looking at the code, this should work correctly since `IsInt` always returns `False` from `isComplete`.

## Safety Assessment

The invariant chain appears **sound** based on code analysis:

1. **Pattern exhaustiveness** is checked before optimization
2. **`isComplete`** correctly identifies finite exhaustive cases
3. **`gatherEdges`** only produces empty fallback when complete
4. **`toDecisionTree`** only creates `Nothing` fallback when edges are exhaustive

However, **there is no explicit assertion** in `treeToDecider` validating this assumption.

## Recommended Guardrails

### Option 1: Add Defensive Crash (Recommended)

```elm
treeToDecider : DT.DecisionTree -> Opt.Decider Int
treeToDecider tree =
    case tree of
        ...
        DT.Decision path edges Nothing ->
            case edges of
                [] ->
                    Utils.Crash.crash "treeToDecider: empty edges with no fallback"

                [ ( _, singleTree ) ] ->
                    -- Single edge with no fallback means it's guaranteed to match
                    treeToDecider singleTree

                _ ->
                    let
                        ( necessaryTests, fallback ) =
                            ( Prelude.init edges, Tuple.second (Prelude.last edges) )
                    in
                    -- Sanity check: ensure edges list isn't unexpectedly long for Bool-like tests
                    -- (This is a defense against corrupted union info)
                    Opt.FanOut
                        path
                        (List.map (Tuple.mapSecond treeToDecider) necessaryTests)
                        (treeToDecider fallback)
        ...
```

### Option 2: Add Debug Assertion for Test Coverage

Validate that the last edge is actually a "catch-all" in some sense:

```elm
DT.Decision path edges Nothing ->
    let
        edgeTests = List.map Tuple.first edges
    in
    if not (isExhaustive edgeTests) then
        Utils.Crash.crash ("treeToDecider: non-exhaustive edges treated as exhaustive: "
                          ++ Debug.toString edgeTests)
    else
        -- ... proceed with current logic
```

Where `isExhaustive` mirrors the `isComplete` logic.

### Option 3: Document the Invariant

At minimum, add a comment explaining the contract:

```elm
-- INVARIANT: When DT.Decision has Nothing as fallback, the edges list
-- forms an exhaustive set of tests. The last edge is treated as the
-- catch-all case. This is guaranteed by:
-- 1. Pattern exhaustiveness checking in Compiler.Reporting.Error.PatternMatches
-- 2. The isComplete function in DecisionTree.elm
-- 3. gatherEdges only returning empty fallback when isComplete returns True
DT.Decision path edges Nothing ->
    ...
```

### Option 4: Type-Level Encoding

Create distinct types for exhaustive vs non-exhaustive decisions:

```elm
type DecisionTree
    = Match Int
    | ExhaustiveDecision Path (NonEmpty ( Test, DecisionTree ))
    | PartialDecision Path (List ( Test, DecisionTree )) DecisionTree
```

This makes the invariant statically checked, but requires refactoring.

## Conclusion

The current code **relies on upstream invariants** that appear to be correctly maintained. The risk is **low** because:

1. Pattern checking catches non-exhaustive matches
2. `isComplete` is conservative (only returns True for provably complete cases)
3. The decision tree construction logic correctly uses `isComplete`

However, adding a defensive `Utils.Crash.crash` for impossible cases would:
- Make the invariant explicit
- Provide better debugging if invariants are ever violated
- Cost nothing at runtime when invariants hold

**Priority**: Low-Medium - Invariants appear sound, but explicit checks aid maintenance and debugging.
