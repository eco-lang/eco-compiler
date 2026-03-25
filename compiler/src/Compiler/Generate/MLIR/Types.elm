module Compiler.Generate.MLIR.Types exposing
    ( ecoValue, ecoInt, ecoFloat, ecoChar
    , monoTypeToAbi, monoTypeToOperand
    , mlirTypeToString
    , isFunctionType, countTotalArity, flattenFunctionType, isEcoValueType
    , isUnboxable
    , RecordLayout, FieldInfo, TupleLayout, CtorLayout
    , computeRecordLayout, computeTupleLayout, computeCtorLayout
    )

{-| MLIR type definitions and conversions.

This module provides:

  - Eco dialect primitive types (ecoValue, ecoInt, ecoFloat, ecoChar)
  - MonoType to MlirType conversion for different contexts
  - Function type utilities
  - Runtime layout types and computation (for codegen)


# Eco Dialect Types

@docs ecoValue, ecoInt, ecoFloat, ecoChar


# Type Conversion by Context

These functions implement the invariant rules for type representation in different contexts.
See design\_docs/invariants.csv for REP\_ABI\_001, REP\_CLOSURE\_001, REP\_SSA\_001, CGEN\_012.

@docs monoTypeToAbi, monoTypeToOperand


# Type String Conversion

@docs mlirTypeToString


# Function Type Utilities

@docs isFunctionType, countTotalArity, flattenFunctionType, isEcoValueType


# Primitive Type Checks

@docs isUnboxable


# Runtime Layouts

Layout types are codegen-specific (they contain unboxing decisions).
These are computed from MonoType shapes during code generation.

@docs RecordLayout, FieldInfo, TupleLayout, CtorLayout


# Layout Computation

@docs computeRecordLayout, computeTupleLayout, computeCtorLayout

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Data.Map as Dict exposing (Dict)
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
            -- Everything else is !eco.value at ABI, including Bool and MVar
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


{-| Count the total number of arguments in a curried function type.
-}
countTotalArity : Mono.MonoType -> Int
countTotalArity monoType =
    case monoType of
        Mono.MFunction argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0


{-| Flatten a curried function type into all ABI parameter types and the result type.
For example, `Int -> String -> Bool -> Char` becomes `([i64, !eco.value, !eco.value], i16)`.
Uses monoTypeToAbi for each parameter and the final result.
-}
flattenFunctionType : Mono.MonoType -> ( List MlirType, MlirType )
flattenFunctionType monoType =
    let
        collectParams : Mono.MonoType -> List Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
        collectParams mt acc =
            case mt of
                Mono.MFunction argTypes result ->
                    collectParams result (acc ++ argTypes)

                _ ->
                    ( acc, mt )

        ( paramMonoTypes, resultMonoType ) =
            collectParams monoType []
    in
    ( List.map monoTypeToAbi paramMonoTypes
    , monoTypeToAbi resultMonoType
    )



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



-- ============================================================================
-- ====== RUNTIME LAYOUTS ======
-- ============================================================================
--
-- These types represent codegen-specific layout information that is computed
-- from MonoType shapes. They contain unboxing decisions and field ordering
-- that depend on the target backend's representation rules.
-- ============================================================================


{-| Runtime layout information for records, including field order and unboxing.
-}
type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int
    , unboxedBitmap : Int
    , fields : List FieldInfo
    }


{-| Information about a single field in a record or constructor.
-}
type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : Mono.MonoType
    , isUnboxed : Bool
    }


{-| Runtime layout information for a single constructor variant.
-}
type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo
    , unboxedCount : Int
    , unboxedBitmap : Int
    }


{-| Runtime layout information for tuples.
-}
type alias TupleLayout =
    { arity : Int
    , unboxedBitmap : Int
    , elements : List ( Mono.MonoType, Bool ) -- (type, isUnboxed)
    }



-- ============================================================================
-- ====== LAYOUT COMPUTATION ======
-- ============================================================================


{-| Compute runtime layout for a record type, ordering fields to place unboxed values first.

This is called during code generation to compute the layout from a record's
field dictionary (stored in MRecord MonoType).

-}
computeRecordLayout : Dict String Name Mono.MonoType -> RecordLayout
computeRecordLayout fields =
    let
        allFields =
            Dict.toList compare fields

        ( unboxedFields, boxedFields ) =
            List.partition (\( _, ty ) -> canUnbox ty) allFields

        sortedUnboxed =
            List.sortBy Tuple.first unboxedFields

        sortedBoxed =
            List.sortBy Tuple.first boxedFields

        orderedFields =
            sortedUnboxed ++ sortedBoxed

        indexedFields =
            List.indexedMap
                (\idx ( name, ty ) ->
                    { name = name
                    , index = idx
                    , monoType = ty
                    , isUnboxed = canUnbox ty
                    }
                )
                orderedFields

        unboxedCount =
            List.length sortedUnboxed

        unboxedBitmap =
            if unboxedCount == 0 then
                0

            else
                (2 ^ unboxedCount) - 1
    in
    { fieldCount = List.length orderedFields
    , unboxedCount = unboxedCount
    , unboxedBitmap = unboxedBitmap
    , fields = indexedFields
    }


{-| Compute runtime layout for a tuple type.

This is called during code generation to compute the layout from a tuple's
element type list (stored in MTuple MonoType).

-}
computeTupleLayout : List Mono.MonoType -> TupleLayout
computeTupleLayout types =
    let
        elements =
            List.map (\t -> ( t, canUnbox t )) types

        unboxedBitmap =
            List.indexedMap
                (\i ( _, isUnboxed ) ->
                    if isUnboxed then
                        2 ^ i

                    else
                        0
                )
                elements
                |> List.sum
    in
    { arity = List.length types
    , unboxedBitmap = unboxedBitmap
    , elements = elements
    }


{-| Compute runtime layout for a constructor from its shape.

This is called during code generation to compute the layout from a
constructor's CtorShape (stored in MonoGraph.ctorShapes).

-}
computeCtorLayout : Mono.CtorShape -> CtorLayout
computeCtorLayout shape =
    let
        fields =
            List.indexedMap
                (\idx ty ->
                    { name = "field" ++ String.fromInt idx
                    , index = idx
                    , monoType = ty
                    , isUnboxed = canUnbox ty
                    }
                )
                shape.fieldTypes

        -- Clamp to 32 bits: the runtime Custom.unboxed field is only 32 bits wide.
        unboxedBitmap =
            List.foldl
                (\field a ->
                    if field.isUnboxed && field.index < 32 then
                        a + (2 ^ field.index)

                    else
                        a
                )
                0
                fields

        unboxedCount =
            List.length (List.filter .isUnboxed fields)
    in
    { name = shape.name
    , tag = shape.tag
    , fields = fields
    , unboxedCount = unboxedCount
    , unboxedBitmap = unboxedBitmap
    }
