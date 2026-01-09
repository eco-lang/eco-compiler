# Kernel ABI Typing Algorithm Implementation Plan

## Summary

Implement the kernel function typing algorithm for monomorphization to fix the `Elm_Kernel_List_cons` signature mismatch error. The algorithm ensures polymorphic kernels like `List.cons` always use a consistent boxed ABI (`eco.value`) regardless of call-site instantiation.

## Problem

When `List.cons : a -> List a -> List a` is called at different sites:
- `List.cons 1 []` produces signature `([I64, eco.value] -> eco.value)`
- `List.cons x []` produces signature `([eco.value, eco.value] -> eco.value)`

The `registerKernelCall` function in MLIR.elm crashes because it requires one signature per kernel.

## Solution

Separate **expression result type** (fully resolved) from **kernel ABI type** (preserves polymorphism for boxed kernels).

---

## Part 1: New Module `Compiler.Generate.Monomorphize.KernelAbi`

Create `compiler/src/Compiler/Generate/Monomorphize/KernelAbi.elm`

### 1.1 Module Header

```elm
module Compiler.Generate.Monomorphize.KernelAbi exposing
    ( deriveKernelFuncMonoType
    , numberBoxedKernels
    )

{-| Kernel ABI type derivation for monomorphization.

This module implements the algorithm that determines the MonoType used for
kernel function ABIs. The key insight is that polymorphic kernels must use
a consistent ABI (all `eco.value`) regardless of call-site type instantiation.

Three cases:
1. **Monomorphic kernels** (e.g., `Basics.modBy : Int -> Int -> Int`):
   ABI matches the concrete types.

2. **Polymorphic kernels** (e.g., `List.cons : a -> List a -> List a`):
   Type variables become `MVar _ CEcoValue`, always boxed.

3. **Number-boxed kernels** (e.g., `Basics.add : number -> number -> number`):
   `CNumber` variables treated as `CEcoValue` for ABI purposes.

-}
```

### 1.2 Constants

```elm
{-| Kernels whose C ABI must box numeric type variables as eco.value.

These are number-polymorphic kernels that go through the boxed C ABI
rather than intrinsic unboxed operations. The intrinsic path in MLIR.elm
handles the fast unboxed Int/Float cases; this ABI is the fallback.
-}
numberBoxedKernels : Set ( String, String )
numberBoxedKernels =
    Set.fromList
        [ ( "Basics", "add" )
        , ( "Basics", "sub" )
        , ( "Basics", "mul" )
        , ( "Basics", "pow" )
        ]


{-| Kernels that are always polymorphic regardless of type variables.

Debug kernels always use boxed ABI because they work with any type.
-}
alwaysPolymorphicModules : Set String
alwaysPolymorphicModules =
    Set.singleton "Debug"
```

### 1.3 Main Algorithm

```elm
{-| Derive the kernel function's MonoType for ABI purposes.

This determines the C ABI signature for calling the kernel. Note that
the expression's result type is computed separately using the call-site
substitution - this function only computes the function type for ABI.

Arguments:
- `(home, name)`: Kernel identifier (e.g., `("List", "cons")`)
- `canFuncType`: Canonical function type from `TOpt.VarKernel`
- `callSubst`: Substitution from unifying call-site argument types

Returns the MonoType to use for the kernel's ABI.
-}
deriveKernelFuncMonoType :
    ( String, String )
    -> Can.Type
    -> Substitution
    -> Mono.MonoType
deriveKernelFuncMonoType ( home, name ) canFuncType callSubst =
    -- Debug kernels are always polymorphic
    if Set.member home alwaysPolymorphicModules then
        canTypeToMonoType_preserveVars canFuncType

    else
        let
            vars =
                freeTypeVariablesWithConstraints canFuncType

            hasEcoVars =
                List.any (\( _, c ) -> c == Mono.CEcoValue) vars

            hasNumberVars =
                List.any (\( _, c ) -> c == Mono.CNumber) vars
        in
        if List.isEmpty vars then
            -- Case A: Monomorphic kernel - fully specialize
            applySubst callSubst canFuncType

        else if hasNumberVars && Set.member ( home, name ) numberBoxedKernels then
            -- Case C: Number-boxed kernel - treat CNumber as CEcoValue
            canTypeToMonoType_numberBoxed canFuncType

        else
            -- Case B: Polymorphic kernel - preserve vars as CEcoValue
            canTypeToMonoType_preserveVars canFuncType
```

### 1.4 Helper Functions

```elm
{-| Extract free type variables with their constraints from a canonical type.
-}
freeTypeVariablesWithConstraints : Can.Type -> List ( Name, Mono.Constraint )
freeTypeVariablesWithConstraints canType =
    freeVarsHelper canType []
        |> List.map (\name -> ( name, constraintFromName name ))


freeVarsHelper : Can.Type -> List Name -> List Name
freeVarsHelper canType acc =
    case canType of
        Can.TVar name ->
            if List.member name acc then
                acc
            else
                name :: acc

        Can.TLambda from to ->
            freeVarsHelper to (freeVarsHelper from acc)

        Can.TType _ _ args ->
            List.foldl freeVarsHelper acc args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ t) a -> freeVarsHelper t a) acc fields

        Can.TTuple a b rest ->
            List.foldl freeVarsHelper acc (a :: b :: rest)

        Can.TUnit ->
            acc

        Can.TAlias _ _ _ (Can.Filled inner) ->
            freeVarsHelper inner acc

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                argVars =
                    List.foldl (\( _, t ) a -> freeVarsHelper t a) acc args
            in
            freeVarsHelper inner argVars


{-| Convert canonical type to MonoType, preserving all type variables as CEcoValue.

Used for polymorphic kernels where the ABI must be all-boxed.
-}
canTypeToMonoType_preserveVars : Can.Type -> Mono.MonoType
canTypeToMonoType_preserveVars canType =
    case canType of
        Can.TVar name ->
            Mono.MVar name Mono.CEcoValue

        Can.TLambda from to ->
            Mono.MFunction
                [ canTypeToMonoType_preserveVars from ]
                (canTypeToMonoType_preserveVars to)

        Can.TType canonical name args ->
            -- Handle primitives and List specially
            let
                monoArgs =
                    List.map canTypeToMonoType_preserveVars args

                isElmCore =
                    case canonical of
                        IO.Canonical ( "elm", "core" ) _ ->
                            True
                        _ ->
                            False
            in
            if isElmCore then
                case name of
                    "Int" -> Mono.MInt
                    "Float" -> Mono.MFloat
                    "Bool" -> Mono.MBool
                    "Char" -> Mono.MChar
                    "String" -> Mono.MString
                    "List" ->
                        case monoArgs of
                            [ inner ] -> Mono.MList inner
                            _ -> Mono.MList Mono.MUnit
                    _ ->
                        Mono.MCustom canonical name monoArgs
            else
                Mono.MCustom canonical name monoArgs

        Can.TRecord fields _ ->
            let
                monoFields =
                    Dict.map (\_ (Can.FieldType _ t) -> canTypeToMonoType_preserveVars t) fields
            in
            Mono.MRecord (Mono.computeRecordLayout monoFields)

        Can.TTuple a b rest ->
            let
                monoTypes =
                    List.map canTypeToMonoType_preserveVars (a :: b :: rest)
            in
            Mono.MTuple (Mono.computeTupleLayout monoTypes)

        Can.TUnit ->
            Mono.MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoType_preserveVars inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            -- For holey aliases, we still preserve vars
            canTypeToMonoType_preserveVars inner


{-| Convert canonical type to MonoType, treating CNumber vars as CEcoValue.

Used for number-boxed kernels (add, sub, mul, pow) where the C ABI is boxed
but the result type should still resolve to MInt or MFloat.
-}
canTypeToMonoType_numberBoxed : Can.Type -> Mono.MonoType
canTypeToMonoType_numberBoxed canType =
    case canType of
        Can.TVar name ->
            -- Treat ALL vars as CEcoValue for ABI purposes
            Mono.MVar name Mono.CEcoValue

        -- All other cases identical to canTypeToMonoType_preserveVars
        Can.TLambda from to ->
            Mono.MFunction
                [ canTypeToMonoType_numberBoxed from ]
                (canTypeToMonoType_numberBoxed to)

        -- ... (same structure as preserveVars, using numberBoxed recursively)
```

---

## Part 2: Update `Compiler.Generate.Monomorphize`

### 2.1 Add Import

```elm
import Compiler.Generate.Monomorphize.KernelAbi as KernelAbi
```

### 2.2 Update Standalone VarKernel (line ~831-842)

**Before:**
```elm
TOpt.VarKernel region home name canType ->
    let
        monoType =
            if isAlwaysPolymorphicKernel home name then
                applySubst Dict.empty canType
            else
                applySubst subst canType
    in
    ( Mono.MonoVarKernel region home name monoType, state )
```

**After:**
```elm
TOpt.VarKernel region home name canType ->
    let
        funcMonoType =
            KernelAbi.deriveKernelFuncMonoType ( home, name ) canType subst
    in
    ( Mono.MonoVarKernel region home name funcMonoType, state )
```

### 2.3 Update VarKernel Call (line ~955-979)

**Before:**
```elm
TOpt.VarKernel funcRegion home name funcCanType ->
    let
        argTypes = List.map Mono.typeOf monoArgs
        callSubst = unifyArgsOnly funcCanType argTypes subst
        resultMonoType = applySubst callSubst canType
        funcMonoType =
            if isAlwaysPolymorphicKernel home name then
                applySubst Dict.empty funcCanType
            else
                applySubst callSubst funcCanType
        monoFunc = Mono.MonoVarKernel funcRegion home name funcMonoType
    in
    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state1 )
```

**After:**
```elm
TOpt.VarKernel funcRegion home name funcCanType ->
    let
        argTypes = List.map Mono.typeOf monoArgs
        callSubst = unifyArgsOnly funcCanType argTypes subst

        -- Expression result: fully resolved
        resultMonoType = applySubst callSubst canType

        -- Kernel ABI: uses algorithm
        funcMonoType = KernelAbi.deriveKernelFuncMonoType ( home, name ) funcCanType callSubst

        monoFunc = Mono.MonoVarKernel funcRegion home name funcMonoType
    in
    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state1 )
```

### 2.4 Update VarDebug Handling (line ~824-829, ~981-1003)

Unify into the same pattern - Debug is now handled by `alwaysPolymorphicModules`:

**Before:**
```elm
TOpt.VarDebug region name _ _ canType ->
    let
        monoType = applySubst subst canType
    in
    ( Mono.MonoVarKernel region "Debug" name monoType, state )
```

**After:**
```elm
TOpt.VarDebug region name _ _ canType ->
    let
        funcMonoType =
            KernelAbi.deriveKernelFuncMonoType ( "Debug", name ) canType subst
    in
    ( Mono.MonoVarKernel region "Debug" name funcMonoType, state )
```

### 2.5 Remove `isAlwaysPolymorphicKernel`

Delete lines 2415-2462 (the entire `-- ========== KERNEL POLYMORPHISM ==========` section).

---

## Part 3: Test Helpers in `CanonicalBuilder.elm`

Add to `compiler/tests/Compiler/AST/CanonicalBuilder.elm`:

```elm
-- Type construction helpers for testing

{-| Create a type variable.
-}
tVar : String -> Can.Type
tVar name =
    Can.TVar name


{-| Create Int type.
-}
tInt : Can.Type
tInt =
    Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Int" []


{-| Create Float type.
-}
tFloat : Can.Type
tFloat =
    Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Float" []


{-| Create Bool type.
-}
tBool : Can.Type
tBool =
    Can.TType (IO.Canonical ( "elm", "core" ) "Basics") "Bool" []


{-| Create String type.
-}
tString : Can.Type
tString =
    Can.TType (IO.Canonical ( "elm", "core" ) "String") "String" []


{-| Create List type.
-}
tList : Can.Type -> Can.Type
tList elem =
    Can.TType (IO.Canonical ( "elm", "core" ) "List") "List" [ elem ]


{-| Create a function type (curried).
-}
tFunc : List Can.Type -> Can.Type -> Can.Type
tFunc args result =
    List.foldr Can.TLambda result args
```

---

## Part 4: Test File `MonomorphizeTest.elm`

Create `compiler/tests/Compiler/Generate/MonomorphizeTest.elm`:

### 4.1 Unit Tests for `deriveKernelFuncMonoType`

```elm
module Compiler.Generate.MonomorphizeTest exposing (suite)

import Compiler.AST.Canonical as Can
import Compiler.AST.CanonicalBuilder exposing (tBool, tFloat, tFunc, tInt, tList, tString, tVar)
import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.Monomorphize.KernelAbi as KernelAbi
import Data.Map as Dict
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Monomorphize.KernelAbi"
        [ monomorphicKernelTests
        , polymorphicKernelTests
        , numberBoxedKernelTests
        , debugKernelTests
        ]


monomorphicKernelTests : Test
monomorphicKernelTests =
    Test.describe "Monomorphic kernels"
        [ Test.test "Basics.modBy : Int -> Int -> Int" <|
            \_ ->
                let
                    canType = tFunc [ tInt, tInt ] tInt
                    result = KernelAbi.deriveKernelFuncMonoType ( "Basics", "modBy" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MInt, Mono.MInt ] Mono.MInt)

        , Test.test "Basics.isInfinite : Float -> Bool" <|
            \_ ->
                let
                    canType = tFunc [ tFloat ] tBool
                    result = KernelAbi.deriveKernelFuncMonoType ( "Basics", "isInfinite" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MFloat ] Mono.MBool)

        , Test.test "String.lines : String -> List String" <|
            \_ ->
                let
                    canType = tFunc [ tString ] (tList tString)
                    result = KernelAbi.deriveKernelFuncMonoType ( "String", "lines" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MString ] (Mono.MList Mono.MString))
        ]


polymorphicKernelTests : Test
polymorphicKernelTests =
    Test.describe "Polymorphic kernels"
        [ Test.test "List.cons : a -> List a -> List a (preserves vars)" <|
            \_ ->
                let
                    canType = tFunc [ tVar "a", tList (tVar "a") ] (tList (tVar "a"))
                    result = KernelAbi.deriveKernelFuncMonoType ( "List", "cons" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MVar "a" Mono.CEcoValue
                        , Mono.MList (Mono.MVar "a" Mono.CEcoValue)
                        ]
                        (Mono.MList (Mono.MVar "a" Mono.CEcoValue))
                    )

        , Test.test "List.cons with Int substitution still uses polymorphic ABI" <|
            \_ ->
                let
                    canType = tFunc [ tVar "a", tList (tVar "a") ] (tList (tVar "a"))
                    subst = Dict.singleton identity "a" Mono.MInt
                    result = KernelAbi.deriveKernelFuncMonoType ( "List", "cons" ) canType subst
                in
                -- ABI should still be polymorphic, NOT specialized to Int
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MVar "a" Mono.CEcoValue
                        , Mono.MList (Mono.MVar "a" Mono.CEcoValue)
                        ]
                        (Mono.MList (Mono.MVar "a" Mono.CEcoValue))
                    )

        , Test.test "Utils.equal : a -> a -> Bool (preserves vars)" <|
            \_ ->
                let
                    canType = tFunc [ tVar "a", tVar "a" ] tBool
                    result = KernelAbi.deriveKernelFuncMonoType ( "Utils", "equal" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MVar "a" Mono.CEcoValue
                        , Mono.MVar "a" Mono.CEcoValue
                        ]
                        Mono.MBool
                    )
        ]


numberBoxedKernelTests : Test
numberBoxedKernelTests =
    Test.describe "Number-boxed kernels"
        [ Test.test "Basics.add : number -> number -> number (in whitelist)" <|
            \_ ->
                let
                    canType = tFunc [ tVar "number", tVar "number" ] (tVar "number")
                    result = KernelAbi.deriveKernelFuncMonoType ( "Basics", "add" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MVar "number" Mono.CEcoValue
                        , Mono.MVar "number" Mono.CEcoValue
                        ]
                        (Mono.MVar "number" Mono.CEcoValue)
                    )

        , Test.test "Basics.sub : number -> number -> number (in whitelist)" <|
            \_ ->
                let
                    canType = tFunc [ tVar "number", tVar "number" ] (tVar "number")
                    result = KernelAbi.deriveKernelFuncMonoType ( "Basics", "sub" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MVar "number" Mono.CEcoValue
                        , Mono.MVar "number" Mono.CEcoValue
                        ]
                        (Mono.MVar "number" Mono.CEcoValue)
                    )
        ]


debugKernelTests : Test
debugKernelTests =
    Test.describe "Debug kernels (always polymorphic)"
        [ Test.test "Debug.log : String -> a -> a" <|
            \_ ->
                let
                    canType = tFunc [ tString, tVar "a" ] (tVar "a")
                    result = KernelAbi.deriveKernelFuncMonoType ( "Debug", "log" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MString
                        , Mono.MVar "a" Mono.CEcoValue
                        ]
                        (Mono.MVar "a" Mono.CEcoValue)
                    )

        , Test.test "Debug.todo : String -> a" <|
            \_ ->
                let
                    canType = tFunc [ tString ] (tVar "a")
                    result = KernelAbi.deriveKernelFuncMonoType ( "Debug", "todo" ) canType Dict.empty
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MString ]
                        (Mono.MVar "a" Mono.CEcoValue)
                    )
        ]
```

### 4.2 End-to-End Test

Add to existing `TypedOptimizedMonomorphizeTest.elm` or create separate integration test that:
1. Compiles Elm source calling `List.cons` with different types
2. Verifies the `MonoVarKernel` has consistent ABI across all calls

---

## File Summary

| File | Action |
|------|--------|
| `compiler/src/Compiler/Generate/Monomorphize/KernelAbi.elm` | **CREATE** - New module with algorithm |
| `compiler/src/Compiler/Generate/Monomorphize.elm` | **MODIFY** - Import KernelAbi, update 4 locations, delete `isAlwaysPolymorphicKernel` |
| `compiler/tests/Compiler/AST/CanonicalBuilder.elm` | **MODIFY** - Add type construction helpers |
| `compiler/tests/Compiler/Generate/MonomorphizeTest.elm` | **CREATE** - Unit tests for algorithm |

---

## Verification

After implementation, run:
```bash
cmake --build build -t check
```

The `Elm_Kernel_List_cons` signature mismatch error should be resolved, and the E2E tests that were crashing should progress further (may still fail for other reasons).
