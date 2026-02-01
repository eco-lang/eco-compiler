# Plan: Extend POST_001 to Cover Lambda and Accessor Expressions

## Overview

This plan extends the POST_001 invariant test (`PostSolveGroupBStructuralTypesTest.elm`) to precisely verify Lambda and Accessor expressions, which are currently skipped with the comment "complex/polymorphic".

### Current State

In `PostSolveGroupBStructuralTypesTest.elm`:
- **Lines 283-294**: Lambda returns `Nothing` (skipped)
- **Lines 296-299**: Accessor returns `Nothing` (skipped)

The test already:
- Uses `syntheticExprIds` from constraint generation
- Only checks expressions where pre-type is a bare `TVar` placeholder
- Uses alpha-equivalence for type comparison

### Goal

Make Lambda and Accessor participate in the same "preType is bare TVar placeholder → must be structurally filled post-PostSolve" rule as the rest of Group B, with precise expected type recomputation.

---

## Step-by-Step Implementation Plan

### Step 1: Add Accessor-Specific Structural Matcher

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

**Problem:** The current generic `alphaEq` is too permissive for Accessor. It accepts:
```
expected: { ext | x : a } -> a
actual:   { ext | x : a } -> b   -- WRONG: different return var
```

For Accessor, the field type and return type MUST be the same variable because PostSolve constructs it as:
```elm
fieldType = Can.TVar "a"
accessorType = Can.TLambda recordType fieldType  -- same fieldType used twice
```

**Add helper function:**

```elm
{-| Check if a type matches the exact Accessor structural shape.

Accessor `.field` must have type `{ ext | field : a } -> a` where:
- The record has an extension variable (not closed)
- The field type is a TVar
- The return type is the SAME TVar as the field type

This is stricter than generic alpha-equivalence because we enforce
that the field type and return type are the same variable.
-}
isAccessorType : Name.Name -> Can.Type -> Bool
isAccessorType fieldName tipe =
    case tipe of
        Can.TLambda recordType retType ->
            case ( recordType, retType ) of
                ( Can.TRecord fields maybeExt, Can.TVar retVar ) ->
                    case maybeExt of
                        Nothing ->
                            -- Must have extension variable
                            False

                        Just _ ->
                            case Dict.get identity fieldName fields of
                                Just (Can.FieldType _ fieldTipe) ->
                                    case fieldTipe of
                                        Can.TVar fieldVar ->
                                            -- Critical invariant: same TVar in both positions
                                            fieldVar == retVar

                                        _ ->
                                            False

                                Nothing ->
                                    False

                _ ->
                    False

        _ ->
            False
```

**Rationale:**
- We require `maybeExt /= Nothing` because PostSolve constructs accessor with an extension variable
- We don't hardcode "a" or "ext", so this remains robust if PostSolve changes names
- We enforce `fieldVar == retVar`, which generic alpha-eq fails to enforce

---

### Step 2: Update Accessor Check to Use Structural Matcher

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

**Change:** In `checkSyntheticPlaceholder`, handle Accessor separately from other Group B expressions:

```elm
checkSyntheticPlaceholder exprId exprNode preType exprNodes artifacts =
    case Dict.get identity exprId artifacts.nodeTypesPost of
        Nothing ->
            -- ... existing error case ...

        Just postType ->
            case exprNode.node of
                Can.Accessor fieldName ->
                    -- Use strict structural check for Accessor
                    if isAccessorType fieldName postType then
                        Nothing
                    else
                        Just
                            { nodeId = exprId
                            , exprKind = "Accessor"
                            , preType = preType
                            , postType = postType
                            , expectedType = Nothing
                            , details = "Accessor type must be { ext | field : a } -> a (same TVar in both positions)"
                            }

                _ ->
                    -- Use existing alphaEq-based check for other Group B expressions
                    let
                        maybeExpected =
                            computeExpectedType exprNode.node artifacts.nodeTypesPost exprNodes
                    in
                    -- ... existing logic ...
```

**Rationale:** This eliminates false positives for Accessor without rewriting the general alpha-eq machinery.

---

### Step 3: Add Strict Pattern Type Lookup (Fail Loudly)

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

**Problem:** The original design suggested skipping (returning `Nothing`) if a lambda parameter has a negative ID. This is wrong because:
- Negative IDs are explicitly "synthetic patterns that won't have types"
- If a lambda parameter ever has a negative ID, that's either an AST bug or analyzing the wrong node
- Silently skipping means POST_001 could stop checking lambdas entirely and still pass

**Add helper type and function:**

```elm
{-| Result of looking up a pattern type, with explicit failure modes.
-}
type PatternTypeLookup
    = PatternTypeFound Can.Type
    | PatternTypeNegativeId Int
    | PatternTypeMissing Int


{-| Look up a pattern's type from nodeTypes with strict error handling.

Lambda parameters should have non-negative IDs and be present in nodeTypes.
Returns an explicit error if either condition is violated.
-}
lookupPatternType : Can.Pattern -> PostSolve.NodeTypes -> PatternTypeLookup
lookupPatternType (A.At _ patInfo) nodeTypes =
    if patInfo.id < 0 then
        PatternTypeNegativeId patInfo.id
    else
        case Dict.get identity patInfo.id nodeTypes of
            Just t ->
                PatternTypeFound t

            Nothing ->
                PatternTypeMissing patInfo.id
```

**Rationale:** Fail loudly with good diagnostics instead of silently skipping.

---

### Step 4: Implement Expected Type for Lambda (With Strict Failure)

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

**Change:** Replace the Lambda case in `computeExpectedType` (lines 283-294):

```elm
Can.Lambda patterns (A.At _ bodyInfo) ->
    expectedLambdaType exprId patterns bodyInfo.id nodeTypes
```

**Note:** We pass `exprId` to include in error messages.

**Add helper functions:**

```elm
{-| Result of computing expected lambda type.
-}
type LambdaTypeResult
    = LambdaTypeOk Can.Type
    | LambdaTypeError String


{-| Compute the expected structural type for a lambda expression.

Lambda `\p1 p2 -> body` has type `p1Type -> p2Type -> bodyType`,
built as a curried chain of TLambda constructors.

Fails loudly if any pattern has a negative ID or missing type.
-}
expectedLambdaType : Int -> List Can.Pattern -> Int -> PostSolve.NodeTypes -> LambdaTypeResult
expectedLambdaType lambdaExprId patterns bodyId nodeTypes =
    case Dict.get identity bodyId nodeTypes of
        Nothing ->
            LambdaTypeError
                ("Lambda " ++ String.fromInt lambdaExprId ++ ": missing body type for id " ++ String.fromInt bodyId)

        Just bodyType ->
            case collectPatternTypes lambdaExprId patterns nodeTypes of
                Err errorMsg ->
                    LambdaTypeError errorMsg

                Ok argTypes ->
                    LambdaTypeOk (buildCurriedFunctionType argTypes bodyType)


{-| Collect all pattern types, failing on first error.
-}
collectPatternTypes : Int -> List Can.Pattern -> PostSolve.NodeTypes -> Result String (List Can.Type)
collectPatternTypes lambdaExprId patterns nodeTypes =
    patterns
        |> List.foldr
            (\pat acc ->
                case acc of
                    Err _ ->
                        acc

                    Ok types ->
                        case lookupPatternType pat nodeTypes of
                            PatternTypeFound t ->
                                Ok (t :: types)

                            PatternTypeNegativeId patId ->
                                Err
                                    ("Lambda " ++ String.fromInt lambdaExprId
                                        ++ ": parameter pattern has negative id " ++ String.fromInt patId
                                        ++ " (unexpected synthetic pattern as lambda param)"
                                    )

                            PatternTypeMissing patId ->
                                Err
                                    ("Lambda " ++ String.fromInt lambdaExprId
                                        ++ ": missing type for parameter pattern id " ++ String.fromInt patId
                                    )
            )
            (Ok [])


{-| Build a curried function type from argument types and body type.

    buildCurriedFunctionType [a, b, c] ret = a -> b -> c -> ret
-}
buildCurriedFunctionType : List Can.Type -> Can.Type -> Can.Type
buildCurriedFunctionType argTypes bodyType =
    List.foldr Can.TLambda bodyType argTypes
```

**Rationale:** The lambda's structural type is fully determined by the post-PostSolve types of its parameter patterns and body expression. Any failure to look up these types is an error, not something to skip.

---

### Step 5: Update checkSyntheticPlaceholder to Handle Lambda Errors

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

**Change:** Handle `LambdaTypeResult` in the checking logic:

```elm
Can.Lambda patterns (A.At _ bodyInfo) ->
    case expectedLambdaType exprId patterns bodyInfo.id artifacts.nodeTypesPost of
        LambdaTypeError errorMsg ->
            Just
                { nodeId = exprId
                , exprKind = "Lambda"
                , preType = preType
                , postType = postType
                , expectedType = Nothing
                , details = errorMsg
                }

        LambdaTypeOk expectedType ->
            if alphaEq postType expectedType then
                Nothing
            else
                Just
                    { nodeId = exprId
                    , exprKind = "Lambda"
                    , preType = preType
                    , postType = postType
                    , expectedType = Just expectedType
                    , details = "Post-type doesn't match expected structural type"
                    }
```

---

## Implementation Checklist

| Step | File | Change |
|------|------|--------|
| 1 | `PostSolveGroupBStructuralTypesTest.elm` | Add `isAccessorType` structural matcher |
| 2 | `PostSolveGroupBStructuralTypesTest.elm` | Update Accessor check to use `isAccessorType` instead of alphaEq |
| 3 | `PostSolveGroupBStructuralTypesTest.elm` | Add `PatternTypeLookup` type and `lookupPatternType` with strict failure |
| 4 | `PostSolveGroupBStructuralTypesTest.elm` | Add `LambdaTypeResult`, `expectedLambdaType`, `collectPatternTypes`, `buildCurriedFunctionType` |
| 5 | `PostSolveGroupBStructuralTypesTest.elm` | Update `checkSyntheticPlaceholder` to handle Accessor and Lambda specially |

---

## Expected Behavior After Implementation

- POST_001 will validate that for recorded Group B synthetic placeholder IDs:
  - **Accessor** post-type is exactly `{ ext | field : a } -> a` with the same TVar in both positions
  - **Lambda** post-type is a curried `TLambda` chain matching `arg1Type -> arg2Type -> ... -> bodyType`

- Test failures will occur if:
  - Accessor post-type has different TVars for field type and return type
  - Accessor post-type lacks an extension variable (closed record)
  - Lambda parameter pattern has a negative ID (AST bug)
  - Lambda parameter pattern type is missing from nodeTypes
  - Lambda body type is missing from nodeTypes
  - Lambda post-type doesn't match the expected curried function type

---

## Questions and Assumptions

### Resolved

1. **Q: Are pattern IDs present in nodeTypesPost?**
   - **A:** Yes, patterns have their own IDs tracked in `nodeTypes`. The constraint generator records pattern types via `recordNodeVar` in pattern constraint functions.

2. **Q: Should we use alphaEq for Accessor?**
   - **A:** No. Generic alphaEq allows `{ ext | x : a } -> b` which is wrong for Accessor. Use strict structural matcher `isAccessorType` that enforces same TVar in field and return positions.

3. **Q: What if a lambda parameter has a negative ID?**
   - **A:** Fail loudly with diagnostics. This indicates an AST bug or wrong node being analyzed. Silently skipping would hide bugs.

4. **Q: Will this cause false positives from legitimate polymorphism?**
   - **A:** No, because the test only checks expressions in `syntheticExprIds` where the pre-type was a bare `TVar`. Legitimate polymorphic functions have structured pre-types.
