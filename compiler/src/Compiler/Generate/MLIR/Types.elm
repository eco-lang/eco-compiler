module Compiler.Generate.MLIR.Types exposing
    ( ecoValue, ecoInt, ecoFloat, ecoChar
    , canUnbox, monoTypeToAbi, monoTypeToOperand
    , mlirTypeToString
    , isFunctionType, functionArity, countTotalArity, decomposeFunctionType, isEcoValueType
    , isUnboxable
    )

{-| MLIR type definitions and conversions.

This module provides:

  - Eco dialect primitive types (ecoValue, ecoInt, ecoFloat, ecoChar)
  - MonoType to MlirType conversion for different contexts
  - Function type utilities


# Eco Dialect Types

@docs ecoValue, ecoInt, ecoFloat, ecoChar


# Type Conversion by Context

These functions implement the invariant rules for type representation in different contexts.
See design\_docs/invariants.csv for REP\_ABI\_001, REP\_CLOSURE\_001, REP\_SSA\_001, CGEN\_012.

@docs canUnbox, monoTypeToAbi, monoTypeToOperand


# Type String Conversion

@docs mlirTypeToString


# Function Type Utilities

@docs isFunctionType, functionArity, countTotalArity, decomposeFunctionType, isEcoValueType


# Primitive Type Checks

@docs isUnboxable

-}

import Compiler.AST.Monomorphized as Mono
import Mlir.Mlir exposing (MlirType(..))



-- ====== ECO DIALECT TYPES ======


{-| eco.value - boxed runtime value
-}
ecoValue : MlirType
ecoValue =
    NamedStruct "eco.value"


{-| eco.int - unboxed 64-bit signed integer
-}
ecoInt : MlirType
ecoInt =
    I64


{-| eco.float - unboxed 64-bit float
-}
ecoFloat : MlirType
ecoFloat =
    F64


{-| eco.char - unboxed character (i16 unicode codepoint, BMP only)
-}
ecoChar : MlirType
ecoChar =
    I16



-- ============================================================================
-- TYPE CONVERSION BY CONTEXT (Invariant Implementation)
-- ============================================================================
--
-- These three functions implement the invariant rules for type representation:
--
--   canUnbox        : Heap/Closure boundary - which MonoTypes can be stored unboxed
--   monoTypeToAbi   : ABI/Closure boundary - function params, returns, closure captures
--   monoTypeToOperand : SSA operand context - internal operations where i1 is valid
--
-- Key rule: Only Int, Float, and Char are unboxable. Bool is NEVER unboxable.
-- Bool may be i1 in SSA operand context but must be !eco.value at ABI/Heap/Closure.
--
-- See: REP_ABI_001, REP_CLOSURE_001, REP_SSA_001, CGEN_012, CGEN_026
-- ============================================================================


{-| Check if a MonoType can be stored unboxed in heap objects and closures.

**Implements**: CGEN\_026, REP\_CLOSURE\_001 (Heap and Closure boundaries)

Only Int, Float, and Char can be unboxed. Bool is NOT unboxable - it must be
stored as !eco.value in heap objects and closures.

-}
canUnbox : Mono.MonoType -> Bool
canUnbox monoType =
    case monoType of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MChar ->
            True

        _ ->
            False


{-| Convert a MonoType to MLIR type for ABI and Closure boundaries.

**Implements**: REP\_ABI\_001, REP\_CLOSURE\_001, CGEN\_012 (ABI and Closure boundaries)

Use this for:

  - Function parameter types
  - Function return types
  - Closure capture types
  - papCreate/papExtend operand types

At these boundaries, only Int (i64), Float (f64), and Char (i16) use primitive
MLIR types. All other types INCLUDING Bool use !eco.value.

-}
monoTypeToAbi : Mono.MonoType -> MlirType
monoTypeToAbi monoType =
    case monoType of
        Mono.MInt ->
            ecoInt

        Mono.MFloat ->
            ecoFloat

        Mono.MChar ->
            ecoChar

        Mono.MVar _ Mono.CNumber ->
            -- Constrained number variables are i64 at ABI
            I64

        _ ->
            -- Everything else is !eco.value at ABI, including Bool
            ecoValue


{-| Convert a MonoType to MLIR type for SSA operand context.

**Implements**: REP\_SSA\_001 (SSA operand context)

Use this for internal SSA operations where Bool may be represented as i1,
such as:

  - Case scrutinee values
  - If condition values
  - Intermediate values in control flow

In SSA context, Bool becomes i1 because it's used for control flow decisions.
This is the ONLY context where i1 is valid for Bool.

-}
monoTypeToOperand : Mono.MonoType -> MlirType
monoTypeToOperand monoType =
    case monoType of
        Mono.MInt ->
            ecoInt

        Mono.MFloat ->
            ecoFloat

        Mono.MBool ->
            I1

        Mono.MChar ->
            ecoChar

        Mono.MString ->
            ecoValue

        Mono.MUnit ->
            ecoValue

        Mono.MList _ ->
            ecoValue

        Mono.MTuple _ ->
            ecoValue

        Mono.MRecord _ ->
            ecoValue

        Mono.MCustom _ _ _ ->
            ecoValue

        Mono.MFunction _ _ ->
            ecoValue

        Mono.MVar _ constraint_ ->
            case constraint_ of
                Mono.CNumber ->
                    I64

                Mono.CEcoValue ->
                    ecoValue


-- ====== FUNCTION TYPE UTILITIES ======


{-| Check if a MonoType is a function type.
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ ->
            True

        _ ->
            False


{-| Count the arity of a function type (number of arrow levels).
-}
functionArity : Mono.MonoType -> Int
functionArity monoType =
    case monoType of
        Mono.MFunction _ result ->
            1 + functionArity result

        _ ->
            0


{-| Count the total number of arguments in a curried function type.
-}
countTotalArity : Mono.MonoType -> Int
countTotalArity monoType =
    case monoType of
        Mono.MFunction argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0


{-| Decompose a function type into its flattened arguments and final result.
-}
decomposeFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
decomposeFunctionType monoType =
    case monoType of
        Mono.MFunction argTypes result ->
            let
                ( nestedArgs, finalResult ) =
                    decomposeFunctionType result
            in
            ( argTypes ++ nestedArgs, finalResult )

        other ->
            ( [], other )



-- ====== TYPE INSPECTION ======


{-| Check if an MLIR type is eco.value (boxed).
-}
isEcoValueType : MlirType -> Bool
isEcoValueType ty =
    case ty of
        NamedStruct "eco.value" ->
            True

        _ ->
            False


{-| Check if an MlirType is an unboxable primitive type (i64, f64, or i16 for char).
Primitive types are stored unboxed in the heap.
-}
isUnboxable : MlirType -> Bool
isUnboxable ty =
    case ty of
        I64 ->
            True

        F64 ->
            True

        I16 ->
            True

        _ ->
            False


{-| Convert an MLIR type to its string representation.
-}
mlirTypeToString : MlirType -> String
mlirTypeToString ty =
    case ty of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct s ->
            s

        FunctionType sig ->
            let
                ins =
                    sig.inputs |> List.map mlirTypeToString |> String.join ", "

                outs =
                    sig.results |> List.map mlirTypeToString |> String.join ", "
            in
            "(" ++ ins ++ ") -> (" ++ outs ++ ")"
