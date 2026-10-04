module Compiler.Generate.MLIR.Types exposing
    ( ecoValue, ecoInt, ecoFloat, ecoChar
    , monoTypeToAbi, monoTypeToOperand
    , mlirTypeToString
    , isFunctionType, countTotalArity, isEcoValueType
    , isUnboxable, mlirTypeToKind, bitmapSetKind
    , RecordLayout, FieldInfo, TupleLayout, CtorLayout
    , computeRecordLayout, computeTupleLayout, computeCtorLayout
    , ctorSlotTypes, isAggCustomType, isAggTupleType, isAggValueType, tupleSlotTypes
    )

{-| The MLIR back end has to decide, for every Elm value, whether it travels as
a raw machine value or as a pointer to a heap object, and this module is where
those decisions are made.

A value that travels as a machine value is _unboxed_: an Int is an `i64`, a
Float an `f64`, a Char an `i16`. Any other value is _boxed_: it is a
`!eco.value`, a reference to a heap object or an embedded constant. The
decision depends on the context the value is in, and the module rests on three
rules, one per context.

The _ABI type_ of a value, given by `monoTypeToAbi`, is its type at a boundary
between pieces of code: function parameters and results, closure captures,
and the operands of partial applications. Int, Float, Char and a number type
variable (`MVar _ CNumber`, which is `i64`) are unboxed there, and everything
else, Bool included, is `!eco.value`.

The _operand type_ of a value, given by `monoTypeToOperand`, is its type as an
SSA value inside a function. It is the ABI type except that a Bool is `i1`, so
that it can drive a branch directly. A Bool read from a boundary or from the
heap is a `!eco.value` and has to be unboxed before it can be used as an `i1`.

Inside a heap object (a record, tuple or constructor) only Int, Float and Char
fields are stored unboxed. A number type variable is boxed there, although it
is `i64` at the ABI.

The rest of the module is the heap rule worked out for each kind of object. A
_layout_ says where each field of a record, tuple or constructor goes and
whether it is unboxed. Each layout carries an _unboxed bitmap_, an `Int` with
two bits per slot, slot `i` occupying bits `2i` and `2i + 1`, holding the slot
kind: 0 boxed, 1 Int, 2 Float, 3 Char. A record field at index 26 or above,
and a constructor field at index 24 or above, is stored boxed even when it
could be unboxed.

The module also recognises _value aggregates_: tuples and constructors held
as SSA values, of types such as `!eco.tuple2<..>` and `!eco.custom<..>`,
rather than as heap objects.

@docs ecoValue, ecoInt, ecoFloat, ecoChar
@docs monoTypeToAbi, monoTypeToOperand
@docs mlirTypeToString
@docs isFunctionType, countTotalArity, isEcoValueType
@docs isUnboxable, mlirTypeToKind, bitmapSetKind
@docs RecordLayout, FieldInfo, TupleLayout, CtorLayout
@docs computeRecordLayout, computeTupleLayout, computeCtorLayout
@docs ctorSlotTypes, isAggCustomType, isAggTupleType, isAggValueType, tupleSlotTypes

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)
import Mlir.Mlir exposing (MlirType(..))



-- ECO DIALECT TYPES


{-| The type of a boxed value, `!eco.value`: a reference to a heap object or
an embedded constant.
-}
ecoValue : MlirType
ecoValue =
    NamedStruct "eco.value"


{-| The type of an unboxed Int, a 64-bit integer.
-}
ecoInt : MlirType
ecoInt =
    I64


{-| The type of an unboxed Float, a 64-bit float.
-}
ecoFloat : MlirType
ecoFloat =
    F64


{-| The type of an unboxed Char, a 16-bit integer.
-}
ecoChar : MlirType
ecoChar =
    I16



-- TYPE CONVERSION BY CONTEXT


{-| Returns whether a value of the given type is stored unboxed in a heap
object: true for Int, Float and Char only. A number type variable is not
unboxed here, although `monoTypeToAbi` makes it `i64`.
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


{-| Returns the ABI type of a value of the given type: its MLIR type as a
function parameter or result, a closure capture, or an operand of a partial
application.

Int is `i64`, Float `f64`, Char `i16`, and a number type variable `i64`.
Every other type, Bool included, is `!eco.value`.

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
            I64

        _ ->
            ecoValue


{-| Returns the operand type of a value of the given type: its MLIR type as an
SSA value inside a function.

This is the ABI type of `monoTypeToAbi` except for Bool, which is `i1`. A
function type is `!eco.value` whatever its lambda set.

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

        Mono.MList _ _ ->
            ecoValue

        Mono.MTuple _ _ ->
            ecoValue

        Mono.MRecord _ _ ->
            ecoValue

        Mono.MCustom _ _ _ _ ->
            ecoValue

        Mono.MFunction _ _ _ _ ->
            ecoValue

        Mono.MVar _ constraint_ ->
            case constraint_ of
                Mono.CNumber ->
                    I64

                Mono.CEcoValue ->
                    ecoValue



-- FUNCTION TYPE UTILITIES


{-| Returns whether the type is a function type.
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Returns the number of arguments a function type takes across all its
stages, counting the arguments of each nested result function. A type that is
not a function has 0.
-}
countTotalArity : Mono.MonoType -> Int
countTotalArity monoType =
    case monoType of
        Mono.MFunction _ _ argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0



-- TYPE INSPECTION


{-| Returns whether the MLIR type is `!eco.value`.
-}
isEcoValueType : MlirType -> Bool
isEcoValueType ty =
    case ty of
        NamedStruct "eco.value" ->
            True

        _ ->
            False


{-| Returns whether the MLIR type is a tuple value aggregate, a
`!eco.tuple2<..>` or `!eco.tuple3<..>`. The test is on the start of the type's
name.
-}
isAggTupleType : MlirType -> Bool
isAggTupleType ty =
    case ty of
        NamedStruct s ->
            String.startsWith "eco.tuple2<" s || String.startsWith "eco.tuple3<" s

        _ ->
            False


{-| Returns whether the MLIR type is a constructor value aggregate, a
`!eco.custom<..>`. The test is on the start of the type's name.
-}
isAggCustomType : MlirType -> Bool
isAggCustomType ty =
    case ty of
        NamedStruct s ->
            String.startsWith "eco.custom<" s

        _ ->
            False


{-| Returns whether the MLIR type is a value aggregate of either kind, tuple or
constructor.
-}
isAggValueType : MlirType -> Bool
isAggValueType ty =
    isAggTupleType ty || isAggCustomType ty


{-| Returns whether the MLIR type is one of the unboxed primitive types,
`i64`, `f64` or `i16`. `i1` is not among them.
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


{-| Returns the slot kind of a value of the given MLIR type, for an unboxed
bitmap: 1 for `i64`, 2 for `f64`, 3 for `i16`, and 0 (boxed) for anything
else. These are the kinds the layouts give Int, Float and Char.
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


{-| Returns the MLIR type as text, for messages. A named type such as
`eco.value` is given without MLIR's leading `!`.
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



-- RUNTIME LAYOUTS


{-| Where each field of a record is stored, and which fields are unboxed.

The fields are in layout order: the unboxed fields first, then the boxed ones,
each group in order of field name by string comparison. A field's `index` is
its position in that order, not in the source.

-}
type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int
    , unboxedBitmap : Int
    , fields : List FieldInfo
    }


{-| One field of a record or constructor layout: its name, its slot index, its
type, and whether it is stored unboxed.

A constructor's fields have no names in the source, so they are named
`field0`, `field1` and so on.

-}
type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : Mono.MonoType
    , isUnboxed : Bool
    }


{-| Where each field of one constructor is stored, and which fields are
unboxed, together with the constructor's name and tag. The fields are in
declaration order.
-}
type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo
    , unboxedCount : Int
    , unboxedBitmap : Int
    }


{-| Which elements of a tuple are stored unboxed. Each entry of `elements` is
an element's type and whether it is unboxed, in element order.
-}
type alias TupleLayout =
    { arity : Int
    , unboxedBitmap : Int
    , elements : List ( Mono.MonoType, Bool )
    }



-- LAYOUT COMPUTATION


{-| Returns the slot kind of an unboxed value of the given type: 1 for Int, 2
for Float, 3 for Char, and 0 (boxed) for anything else.
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


{-| The number of slots an unboxed bitmap can describe. Twenty-six two-bit
slots take 52 bits; a 27th would need 54, more than the 53 bits an Elm `Int`
holds exactly. The bitmap records no kind for a slot at this index or above, so
it reads as boxed there.
-}
maxTypedSlots : Int
maxTypedSlots =
    26


{-| Returns `bitmap` with the kind of slot `index` replaced by `kind`. An
`index` of `maxTypedSlots` (26) or above leaves the bitmap unchanged, so that
slot reads as boxed.

The bitmap is computed with ordinary `Int` arithmetic rather than `Bitwise`,
whose operations are 32-bit and so could reach only 16 slots. Arithmetic is
exact up to 2^53, which covers 26 slots.

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


{-| Returns the layout of a record with the given fields.

The unboxed fields come first, then the boxed ones, each group in order of
field name by string comparison, and the indices follow that order. A field at
index 26 or above is stored boxed even if its type could be unboxed.

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

        -- Capped by index so that a field the bitmap cannot describe is stored boxed.
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


{-| Returns the MLIR type of each slot of a tuple layout, in element order: the
ABI type of an unboxed element, and `!eco.value` for a boxed one.
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


{-| Returns the MLIR type of each slot of a constructor layout, in field order:
the ABI type of an unboxed field, and `!eco.value` for a boxed one.
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


{-| Returns the layout of a tuple with the given element types. Every Int,
Float or Char element is unboxed; no index cap is applied.
-}
computeTupleLayout : List Mono.MonoType -> TupleLayout
computeTupleLayout types =
    let
        elements =
            List.map (\t -> ( t, canUnbox t )) types

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


{-| Returns the layout of a constructor from its shape. The fields keep their
declaration order and are named `field0`, `field1` and so on. A field at index
24 or above is stored boxed even if its type could be unboxed.
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
