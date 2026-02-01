# Plan: Fix TOPT_004 to Catch MONO_018-Class Bugs

## Problem Statement

The current TOPT_004 implementation uses permissive alpha-equivalence that treats `TVar` as a wildcard:
- `TVar` matches any `TVar` (no consistent mapping)
- `TVar` matches any concrete type

This makes TOPT_004 **incapable of catching the key bug shape**:

```
case : List Int
branch expression has type : List a
```

Because it hits the element `TVar` and accepts it. This is exactly the "polymorphic remnant under structure" that later becomes `MVar "a" CEcoValue` and fails MONO_018.

---

## Design Overview

### Key Change

Introduce **two** type comparators:

1. **`alphaEqStrict`** - Real alpha-equivalence with **consistent renaming** of type variables and record extension variables.
   - `TVar` only matches `TVar`, and only via a consistent mapping
   - `TVar` does **not** match a concrete type

2. **`alphaEqLoose`** (optional) - Retains permissive behavior where `TVar` may match anything.
   - Used only where intentional imprecision is needed

### Where to Use Strict vs Loose

Use **strict** equivalence for checks that must catch MONO_018-class problems:
- Case result type vs Inline leaf expression type
- Case result type vs Jump target expression type
- VarLocal type vs environment binding type
- VarKernel type vs KernelTypeEnv entry type

Everything else remains "recursive traversal only".

---

## Step-by-Step Implementation Plan

### Step 1: Create Shared Strict Alpha-Equivalence Module

**File:** `compiler/tests/Compiler/Optimize/Typed/TypeEq.elm`

**Purpose:** Provide `alphaEqStrict` for comparing `Can.Type` values robustly.

#### 1.1: Define AlphaState

```elm
module Compiler.Optimize.Typed.TypeEq exposing
    ( alphaEqStrict
    , alphaEqLoose
    )

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Data.Map as Dict exposing (Dict)


{-| State for tracking consistent TVar and extension var mappings.
-}
type alias AlphaState =
    { tvarsL2R : Dict String Name.Name Name.Name
    , tvarsR2L : Dict String Name.Name Name.Name
    , extL2R : Dict String Name.Name Name.Name
    , extR2L : Dict String Name.Name Name.Name
    }


emptyState : AlphaState
emptyState =
    { tvarsL2R = Dict.empty
    , tvarsR2L = Dict.empty
    , extL2R = Dict.empty
    , extR2L = Dict.empty
    }
```

#### 1.2: Implement alphaEqStrict

```elm
{-| Strict alpha-equivalence with consistent TVar renaming.

TVar only matches TVar via a consistent bidirectional mapping.
TVar does NOT match a concrete type.
-}
alphaEqStrict : Can.Type -> Can.Type -> Bool
alphaEqStrict t1 t2 =
    case alphaEqStrictHelp emptyState t1 t2 of
        Just _ -> True
        Nothing -> False


alphaEqStrictHelp : AlphaState -> Can.Type -> Can.Type -> Maybe AlphaState
alphaEqStrictHelp state t1 t2 =
    case ( t1, t2 ) of
        ( Can.TVar a, Can.TVar b ) ->
            -- Check/extend consistent mapping
            matchTVars state a b

        ( Can.TVar _, _ ) ->
            -- TVar does NOT match non-TVar in strict mode
            Nothing

        ( _, Can.TVar _ ) ->
            Nothing

        ( Can.TType h1 n1 args1, Can.TType h2 n2 args2 ) ->
            if canonicalTypesEqual h1 n1 h2 n2 && List.length args1 == List.length args2 then
                alphaEqStrictList state args1 args2
            else
                Nothing

        ( Can.TLambda a1 b1, Can.TLambda a2 b2 ) ->
            alphaEqStrictHelp state a1 a2
                |> Maybe.andThen (\s -> alphaEqStrictHelp s b1 b2)

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            alphaEqStrictRecord state fields1 ext1 fields2 ext2

        ( Can.TUnit, Can.TUnit ) ->
            Just state

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            if List.length cs1 == List.length cs2 then
                alphaEqStrictHelp state a1 a2
                    |> Maybe.andThen (\s -> alphaEqStrictHelp s b1 b2)
                    |> Maybe.andThen (\s -> alphaEqStrictList s cs1 cs2)
            else
                Nothing

        ( Can.TAlias _ _ args1 at1, Can.TAlias _ _ args2 at2 ) ->
            -- Unwrap with substitution and compare underlying types
            let
                body1 = unwrapAliasWithSubst args1 at1
                body2 = unwrapAliasWithSubst args2 at2
            in
            alphaEqStrictHelp state body1 body2

        ( Can.TAlias _ _ args at, other ) ->
            alphaEqStrictHelp state (unwrapAliasWithSubst args at) other

        ( other, Can.TAlias _ _ args at ) ->
            alphaEqStrictHelp state other (unwrapAliasWithSubst args at)

        _ ->
            Nothing
```

#### 1.3: TVar Consistent Mapping

```elm
{-| Match two TVars with consistent bidirectional mapping.
-}
matchTVars : AlphaState -> Name.Name -> Name.Name -> Maybe AlphaState
matchTVars state a b =
    case ( Dict.get identity a state.tvarsL2R, Dict.get identity b state.tvarsR2L ) of
        ( Just mappedB, Just mappedA ) ->
            -- Both already mapped; must be consistent
            if mappedB == b && mappedA == a then
                Just state
            else
                Nothing

        ( Just mappedB, Nothing ) ->
            -- a is mapped but b is not reverse-mapped
            if mappedB == b then
                Just { state | tvarsR2L = Dict.insert identity b a state.tvarsR2L }
            else
                Nothing

        ( Nothing, Just mappedA ) ->
            -- b is reverse-mapped but a is not mapped
            if mappedA == a then
                Just { state | tvarsL2R = Dict.insert identity a b state.tvarsL2R }
            else
                Nothing

        ( Nothing, Nothing ) ->
            -- Neither mapped; create new mapping
            Just
                { state
                    | tvarsL2R = Dict.insert identity a b state.tvarsL2R
                    , tvarsR2L = Dict.insert identity b a state.tvarsR2L
                }
```

#### 1.4: Record Comparison with Extension Var Mapping

```elm
alphaEqStrictRecord :
    AlphaState
    -> Dict String Name.Name Can.FieldType
    -> Maybe Name.Name
    -> Dict String Name.Name Can.FieldType
    -> Maybe Name.Name
    -> Maybe AlphaState
alphaEqStrictRecord state fields1 ext1 fields2 ext2 =
    let
        keys1 = Dict.keys compare fields1
        keys2 = Dict.keys compare fields2
    in
    if keys1 /= keys2 then
        Nothing
    else
        -- Compare extension variables using separate ext-var mapping
        matchExtVars state ext1 ext2
            |> Maybe.andThen (\s -> alphaEqStrictFields s keys1 fields1 fields2)


matchExtVars : AlphaState -> Maybe Name.Name -> Maybe Name.Name -> Maybe AlphaState
matchExtVars state ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            Just state

        ( Just a, Just b ) ->
            -- Use same logic as TVars but with ext mappings
            case ( Dict.get identity a state.extL2R, Dict.get identity b state.extR2L ) of
                ( Just mappedB, Just mappedA ) ->
                    if mappedB == b && mappedA == a then Just state else Nothing

                ( Just mappedB, Nothing ) ->
                    if mappedB == b then
                        Just { state | extR2L = Dict.insert identity b a state.extR2L }
                    else Nothing

                ( Nothing, Just mappedA ) ->
                    if mappedA == a then
                        Just { state | extL2R = Dict.insert identity a b state.extL2R }
                    else Nothing

                ( Nothing, Nothing ) ->
                    Just
                        { state
                            | extL2R = Dict.insert identity a b state.extL2R
                            , extR2L = Dict.insert identity b a state.extR2L
                        }

        _ ->
            Nothing
```

#### 1.5: Alias Unwrapping with Substitution

```elm
{-| Unwrap alias, applying argument substitutions to the body.

Critical: Canonical aliases have argument bindings that must be substituted
into the alias body before comparison.
-}
unwrapAliasWithSubst : List ( Name.Name, Can.Type ) -> Can.AliasType -> Can.Type
unwrapAliasWithSubst args aliasType =
    let
        subst =
            Dict.fromList identity args

        body =
            case aliasType of
                Can.Filled t -> t
                Can.Holey t -> t
    in
    applySubst subst body


applySubst : Dict String Name.Name Can.Type -> Can.Type -> Can.Type
applySubst subst tipe =
    case tipe of
        Can.TVar name ->
            case Dict.get identity name subst of
                Just replacement -> replacement
                Nothing -> tipe

        Can.TType home name args ->
            Can.TType home name (List.map (applySubst subst) args)

        Can.TLambda a b ->
            Can.TLambda (applySubst subst a) (applySubst subst b)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map compare (\_ (Can.FieldType idx t) -> Can.FieldType idx (applySubst subst t)) fields)
                ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b cs ->
            Can.TTuple (applySubst subst a) (applySubst subst b) (List.map (applySubst subst) cs)

        Can.TAlias home name args at ->
            -- Recursively apply to alias args
            Can.TAlias home name
                (List.map (\( n, t ) -> ( n, applySubst subst t )) args)
                at
```

#### 1.6: Helper for Canonical Type Equality (Re-export Handling)

```elm
{-| Check if two canonical type references are equal, handling re-exports.

In Elm, types like String can appear as both Basics.String and String.String
within the same package. For type checking, these are equivalent.
-}
canonicalTypesEqual : IO.Canonical -> String -> IO.Canonical -> String -> Bool
canonicalTypesEqual (IO.Canonical pkg1 _) name1 (IO.Canonical pkg2 _) name2 =
    pkg1 == pkg2 && name1 == name2
```

---

### Step 2: Update TOPT_004 to Use Strict Equality for Critical Checks

**File:** `compiler/tests/Compiler/Optimize/TypePreservation.elm`

#### 2.1: Import TypeEq Module

```elm
import Compiler.Optimize.Typed.TypeEq as TypeEq
```

#### 2.2: Update Case/Decider Checking

Replace permissive `alphaEq` with `TypeEq.alphaEqStrict`:

```elm
checkChoice : TypeEnv -> String -> Can.Type -> TOpt.Choice -> List Violation
checkChoice env context expectedType choice =
    case choice of
        TOpt.Inline expr ->
            let
                exprType = TOpt.typeOf expr
            in
            if TypeEq.alphaEqStrict exprType expectedType then
                checkExpr env context expr
            else
                [ violation context "Inline" exprType (Just expectedType)
                    "Inline expression type doesn't match Case result type (strict)"
                ]

        TOpt.Jump _ ->
            []


checkJumps : TypeEnv -> String -> Can.Type -> List ( Int, TOpt.Expr ) -> List Violation
checkJumps env context expectedType jumps =
    List.concatMap
        (\( idx, expr ) ->
            let
                exprType = TOpt.typeOf expr
            in
            if TypeEq.alphaEqStrict exprType expectedType then
                checkExpr env context expr
            else
                [ violation context ("Jump target " ++ String.fromInt idx) exprType (Just expectedType)
                    "Jump target type doesn't match Case result type (strict)"
                ]
        )
        jumps
```

#### 2.3: Update VarLocal Checking

```elm
        TOpt.VarLocal name tipe ->
            case Dict.get identity name env.locals of
                Just envType ->
                    if TypeEq.alphaEqStrict tipe envType then
                        []
                    else
                        [ violation context "VarLocal" tipe (Just envType)
                            ("Variable '" ++ name ++ "' type doesn't match binding (strict)")
                        ]

                Nothing ->
                    []
```

#### 2.4: Update VarKernel Checking

```elm
        TOpt.VarKernel _ home name tipe ->
            case KernelTypes.lookup home name env.kernelEnv of
                Just kernelType ->
                    if TypeEq.alphaEqStrict tipe kernelType then
                        []
                    else
                        [ violation context "VarKernel" tipe (Just kernelType)
                            ("Kernel '" ++ home ++ "." ++ name ++ "' type doesn't match KernelTypeEnv (strict)")
                        ]

                Nothing ->
                    []
```

---

### Step 3: Add Coverage Guards

**File:** `compiler/tests/Compiler/Optimize/TypePreservation.elm`

#### 3.1: Add Counters to Check State

```elm
type alias CheckState =
    { violations : List Violation
    , casesSeen : Int
    , inlineLeavesSeen : Int
    , jumpBranchesSeen : Int
    }


emptyCheckState : CheckState
emptyCheckState =
    { violations = []
    , casesSeen = 0
    , inlineLeavesSeen = 0
    , jumpBranchesSeen = 0
    }
```

#### 3.2: Increment Counters During Traversal

```elm
        TOpt.Case _ _ decider jumps tipe ->
            let
                state1 = { state | casesSeen = state.casesSeen + 1 }
                state2 = checkDecider env context tipe decider state1
                state3 = checkJumps env context tipe jumps state2
            in
            state3
```

#### 3.3: Assert Coverage at End of Suite

```elm
expectTypePreservation : Src.Module -> Expect.Expectation
expectTypePreservation srcModule =
    case runToTypedOptimizedWithKernelEnv srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                finalState = checkLocalGraph env artifacts.localGraph emptyCheckState
            in
            if not (List.isEmpty finalState.violations) then
                Expect.fail (formatViolations finalState.violations)
            else
                -- Coverage guard: ensure we actually checked some cases
                Expect.pass
```

**Note:** The coverage assertion can be added to a summary test that runs after all individual tests, asserting `totalCasesSeen > 0`.

---

### Step 4: Keep Lightweight Checks for Everything Else

The following remain "recursive traversal only" (no type assertions):

- Literal types (Int/Float/etc. have polymorphic `number` types)
- Function type = params → body type (polymorphic functions)
- Call result type (polymorphism)
- VarGlobal scheme instantiation (complex)
- If branch type matching (polymorphism)

But ensure **exhaustive traversal** so Case/Inline nodes deep inside let/function bodies are reached.

---

### Step 5: Wire Into Test Suite

**File:** `compiler/tests/Compiler/InvariantTests.elm`

Already done - `TypedOptimizedTypePreservationTest.suite` is included in `typedOptimizationInvariants`.

---

## Implementation Checklist

| Step | File | Change |
|------|------|--------|
| 1 | `Compiler/Optimize/Typed/TypeEq.elm` | Create new module with `alphaEqStrict` |
| 2.1 | `TypePreservation.elm` | Import TypeEq module |
| 2.2 | `TypePreservation.elm` | Update Case/Decider checks to use strict |
| 2.3 | `TypePreservation.elm` | Update VarLocal checks to use strict |
| 2.4 | `TypePreservation.elm` | Update VarKernel checks to use strict |
| 3 | `TypePreservation.elm` | Add coverage counters |
| 4 | `TypePreservation.elm` | Keep lightweight checks for other expressions |

---

## Why This Design Is Correct

1. **Restores alpha-equivalence to its proper meaning**: equality up to consistent renaming, not "TVar matches anything"

2. **Uses strictness exactly where needed**: Case result types vs branch expression types - the earliest practical place to catch MONO_018-class bugs

3. **Proper alias handling**: Substitutes alias arguments before comparing, avoiding false positives/negatives

4. **Record extension variables**: Uses separate consistent mapping, avoiding spurious failures

5. **Maintains lightweight scope**: Only the critical checks (Case/VarLocal/VarKernel) are strict; everything else remains traversal-only

---

## Expected Behavior After Implementation

- **Catches**: `case : List Int` with branch expression type `List a`
- **Catches**: VarLocal with polymorphic remnant type when binding is concrete
- **Catches**: VarKernel type mismatch with KernelTypeEnv
- **Passes**: Legitimate polymorphic code where TVars are consistently used

---

## Notes / Gotchas

1. **Alias unwrapping must substitute arguments** - Canonical aliases have argument bindings in the `TAlias` node; apply them before comparing

2. **Record extension variables** - Use same consistent mapping approach as type variables

3. **Destructuring / negative pattern IDs** - TOPT_004 doesn't reason about pattern IDs directly; just ensure traversal enters destruct bodies so Case checks still run
