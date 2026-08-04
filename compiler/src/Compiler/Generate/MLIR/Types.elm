module Compiler.Generate.MLIR.Types exposing
    ( ecoValue, ecoInt, ecoFloat, ecoChar
    , monoTypeToAbi, monoTypeToOperand
    , mlirTypeToString
    , isFunctionType, countTotalArity, isEcoValueType, isAggTupleType, isAggCustomType, isAggValueType
    , isUnboxable, mlirTypeToKind, bitmapSetKind
    , RecordLayout, FieldInfo, TupleLayout, CtorLayout
    , computeRecordLayout, computeTupleLayout, computeCtorLayout, tupleSlotTypes, ctorSlotTypes
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

@docs isFunctionType, countTotalArity, isEcoValueType


# Primitive Type Checks

@docs isUnboxable, mlirTypeToKind, bitmapSetKind


# Runtime Layouts

Layout types are codegen-specific (they contain unboxing decisions).
These are computed from MonoType shapes during code generation.

@docs RecordLayout, FieldInfo, TupleLayout, CtorLayout


# Layout Computation

@docs computeRecordLayout, computeTupleLayout, computeCtorLayout

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)
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

        Mono.MFunction _ _ _ ->
            -- Layout ignores the lambda-set annotation: an arrow is a boxed
            -- closure value regardless of its set (REP_* untouched).
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
        Mono.MFunction _ _ _ ->
            True

        _ ->
            False


{-| Count the total number of arguments in a curried function type.
-}
countTotalArity : Mono.MonoType -> Int
countTotalArity monoType =
    case monoType of
        Mono.MFunction _ argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0



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


{-| Check if an MLIR type is a VALUE-level tuple aggregate
(`!eco.tuple2<...>` / `!eco.tuple3<...>`, U-T1.3.1 promoted form).
-}
isAggTupleType : MlirType -> Bool
isAggTupleType ty =
    case ty of
        NamedStruct s ->
            String.startsWith "eco.tuple2<" s || String.startsWith "eco.tuple3<" s

        _ ->
            False


{-| Check if an MLIR type is a VALUE-level custom aggregate
(`!eco.custom<...>`, U-T1.3.2 promoted ctor form).
-}
isAggCustomType : MlirType -> Bool
isAggCustomType ty =
    case ty of
        NamedStruct s ->
            String.startsWith "eco.custom<" s

        _ ->
            False


{-| Any promoted value-aggregate form (tuple or custom).
-}
isAggValueType : MlirType -> Bool
isAggValueType ty =
    isAggTupleType ty || isAggCustomType ty


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


{-| Encode an `MlirType` as a 2-bit primitive kind matching
`encodeUnboxedKind` for `MonoType`:

  - `I64` -> 1 (Int)
  - `F64` -> 2 (Float)
  - `I16` -> 3 (Char)
  - anything else -> 0 (boxed)

-}
mlirTypeToKind : MlirType -> Int
mlirTypeToKind ty =
    case ty of
        I64 ->
            1

        F64 ->
            2

        I16 ->
            3

        _ ->
            0


{-| Convert an MLIR type to its string representation.
-}
mlirTypeToString : MlirType -> String
mlirTypeToString ty =
    case ty of
        I1 ->
            "i1"

        I8 ->
            "i8"

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


{-| Encodes a monotype as a 2-bit primitive kind:

  - `Mono.MInt` -> 1 (i64)
  - `Mono.MFloat` -> 2 (f64)
  - `Mono.MChar` -> 3 (u16)
  - anything else -> 0 (boxed HPointer)

-}
encodeUnboxedKind : Mono.MonoType -> Int
encodeUnboxedKind monoType =
    case monoType of
        Mono.MInt ->
            1

        Mono.MFloat ->
            2

        Mono.MChar ->
            3

        _ ->
            0


{-| Maximum number of 2-bit typed slots representable in an Elm-computed
bitmap: 26 slots = 52 bits, within Int's exact range (2^53). This also
equals the closure header's 52-bit unboxed field (REP\_CLOSURE\_001).
Runtime containers allow up to 32 (Record) / 24 (Custom) typed slots; the
effective cap per container is the minimum of this and the container's own
capacity. Fields at or beyond the cap must be stored boxed (kind 00).
-}
maxTypedSlots : Int
maxTypedSlots =
    26


{-| Sets the 2-bit kind at slot `index` into an Int-encoded bitmap.

Implemented with exact Int arithmetic, NOT Bitwise: Elm's Bitwise operates
on 32-bit values (JS semantics — shift counts wrap at 32), which silently
corrupted bitmaps for containers with more than 16 slots. A slot at index
i >= 16 wrapped onto slot (i - 16), and writing kind 00 there CLEARED the
low slot's real kind — e.g. a 23-field record with an unboxed Int at slot
0 emitted bitmap 0 (all boxed), so the GC scanned the raw Int as a pointer
("Pointer below heap base" abort). Plain Int arithmetic is exact up to
2^53, covering `maxTypedSlots` (26) two-bit slots; dividing by a power of
two and flooring is exact in both the JS and native backends, so the two
bootstrap pipelines compute identical bitmaps.

Slots at index >= `maxTypedSlots` are left boxed (00); callers must demote
such fields to boxed storage (see computeRecordLayout/computeCtorLayout).
-}
bitmapSetKind : Int -> Int -> Int -> Int
bitmapSetKind bitmap index kind =
    if index >= maxTypedSlots then
        bitmap

    else
        let
            weight =
                4 ^ index

            current =
                modBy 4 (floor (toFloat bitmap / toFloat weight))
        in
        bitmap + (modBy 4 kind - current) * weight


{-| Compute runtime layout for a record type, ordering fields to place unboxed values first.

This is called during code generation to compute the layout from a record's
field dictionary (stored in MRecord MonoType).

-}
computeRecordLayout : Dict Name Mono.MonoType -> RecordLayout
computeRecordLayout fields =
    let
        allFields =
            Dict.toList fields

        ( unboxedFields, boxedFields ) =
            List.partition (\( _, ty ) -> canUnbox ty) allFields

        sortedUnboxed =
            List.sortBy Tuple.first unboxedFields

        sortedBoxed =
            List.sortBy Tuple.first boxedFields

        orderedFields =
            sortedUnboxed ++ sortedBoxed

        -- Fields at index >= maxTypedSlots demote to boxed storage: isUnboxed
        -- is index-capped so the projection type, the stored value (boxed by
        -- generateRecordCreate), and the GC bitmap all agree (REP_BOUNDARY_002).
        -- The runtime Record bitmap holds 32 slots, but Elm-side bitmap
        -- arithmetic is exact only to 26 (see maxTypedSlots).
        indexedFields =
            List.indexedMap
                (\idx ( name, ty ) ->
                    { name = name
                    , index = idx
                    , monoType = ty
                    , isUnboxed = canUnbox ty && idx < maxTypedSlots
                    }
                )
                orderedFields

        unboxedCount =
            List.length (List.filter .isUnboxed indexedFields)

        unboxedBitmap =
            List.foldl
                (\field acc ->
                    let
                        kind =
                            if field.isUnboxed then
                                encodeUnboxedKind field.monoType

                            else
                                0
                    in
                    bitmapSetKind acc field.index kind
                )
                0
                indexedFields
    in
    { fieldCount = List.length orderedFields
    , unboxedCount = unboxedCount
    , unboxedBitmap = unboxedBitmap
    , fields = indexedFields
    }


{-| U-T1.3.3: the per-slot STORED MLIR types of a tuple layout — unboxed
element ⇒ its ABI primitive, boxed ⇒ `!eco.value`. Shared by scalar-split
loop vars, sret workers, and their call sites so the forms cannot drift.
-}
tupleSlotTypes : TupleLayout -> List MlirType
tupleSlotTypes layout =
    List.map
        (\( elemTy, isUnboxed ) ->
            if isUnboxed then
                monoTypeToAbi elemTy

            else
                ecoValue
        )
        layout.elements


{-| U-T1.3.5: the per-slot STORED MLIR types of a ctor layout — the
custom-shape analog of `tupleSlotTypes`.
-}
ctorSlotTypes : CtorLayout -> List MlirType
ctorSlotTypes layout =
    List.map
        (\f ->
            if f.isUnboxed then
                monoTypeToAbi f.monoType

            else
                ecoValue
        )
        layout.fields


{-| Compute runtime layout for a tuple type.

This is called during code generation to compute the layout from a tuple's
element type list (stored in MTuple MonoType).

-}
computeTupleLayout : List Mono.MonoType -> TupleLayout
computeTupleLayout types =
    let
        elements =
            List.map (\t -> ( t, canUnbox t )) types

        -- 2-bit kind per slot; tuples have up to 3 slots (6 bits).
        unboxedBitmap =
            List.indexedMap Tuple.pair elements
                |> List.foldl
                    (\( i, ( ty, isUnboxed ) ) acc ->
                        let
                            kind =
                                if isUnboxed then
                                    encodeUnboxedKind ty

                                else
                                    0
                        in
                        bitmapSetKind acc i kind
                    )
                    0
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
        -- Custom.unboxed is 48 bits wide; 2-bit kinds fit up to 24 fields.
        -- Fields at index >= 24 demote to BOXED STORAGE (not just bitmap kind
        -- 0): isUnboxed is index-capped so the stored value, projection type,
        -- and GC bitmap agree (REP_BOUNDARY_002). The verifier's size <= 24
        -- check in EcoOps.cpp catches the overflow if an overflowing
        -- constructor is actually emitted.
        fields =
            List.indexedMap
                (\idx ty ->
                    { name = "field" ++ String.fromInt idx
                    , index = idx
                    , monoType = ty
                    , isUnboxed = canUnbox ty && idx < 24
                    }
                )
                shape.fieldTypes

        unboxedBitmap =
            List.foldl
                (\field acc ->
                    let
                        kind =
                            if field.isUnboxed then
                                encodeUnboxedKind field.monoType

                            else
                                0
                    in
                    bitmapSetKind acc field.index kind
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
