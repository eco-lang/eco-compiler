module Compiler.Generate.MLIR.LogicalTypes exposing
    ( LogicalTypeDesc, AggKind
    , addLogicalTypesAttr, addLogicalTypesAttrUnknown
    )

{-| An emitted function's MLIR signature says how each value is passed, not what
Elm type it has, and this module records the Elm-level shape alongside it.

A function's ABI type for a parameter is `i64`, `f64`, `i16`, `i1` or
`!eco.value`. A tuple, a record, a list and a custom value all pass as
`!eco.value`, so the signature cannot say whether a parameter is, say, a pair
of an `Int` and a `Float`. The _logical type_ of a parameter or result is that
shape: which aggregate it is and what kind each of its elements has. This module
attaches the logical types to a `func.func` op as two array attributes of
strings, `eco.logical_param_types` with one entry per parameter and
`eco.logical_result_types` with one entry for the result. Anything that reads
them later can tell which functions take or return a small aggregate whose
elements are primitive.

An Elm type is first described as a `LogicalTypeDesc`, then rendered as a
string, the _wire format_:

  - `"i64"`, `"f64"`, `"i16"`, `"i1"` for a primitive.
  - `"value"` for anything else, and for a type whose shape is not known.
  - `"tuple2:K:K"` and `"tuple3:K:K:K"` for a tuple of two or three elements.
  - `"record:N:K..."` for a record of N fields, listed in the order
    `Types.computeRecordLayout` gives them.
  - `"custom:Tag:N:K..."` for a custom type with exactly one constructor, whose
    tag is Tag and whose N fields number between one and a limit the caller
    passes.
  - `"cons:K:v"` for a list.

Each `K` is an _aggregate kind_, one character saying what an element is: `i`
for `Int`, `f` for `Float`, `c` for `Char`, and `v` for anything else, nested
aggregates included. The kind comes from the element's Elm type alone, not from
how a heap object stores it.

@docs LogicalTypeDesc, AggKind
@docs addLogicalTypesAttr, addLogicalTypesAttrUnknown

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))


{-| The logical type of one parameter or result: its Elm-level shape, before it
is rendered as a wire-format string.

`LValue` is any type with no more specific description, including `Bool`,
`String`, the unit type, functions, type variables, tuples of other sizes and
most custom types.

`LI64`, `LF64` and `LI16` are `Int`, `Float` and `Char`. `LI1` comes only from
an `i1` ABI type, never from an Elm type.

`LTuple2` and `LTuple3` carry the kind of each element in order. `LRecord`
carries the kind of each field in record layout order, and its field count is
the length of that list. `LCustom` carries the constructor's tag and the kind of
each of its fields. `LCons` carries the kind of the list's head and of its tail,
which is always `AKValue` here.

`LUnknown` means the logical type could not be determined. It renders as
`"value"`, the same string as `LValue`, so nothing reading the attribute can
tell the two apart.

-}
type LogicalTypeDesc
    = LValue
    | LI64
    | LF64
    | LI16
    | LI1
    | LTuple2 AggKind AggKind
    | LTuple3 AggKind AggKind AggKind
    | LRecord (List AggKind)
    | LCustom { tag : Int, fields : List AggKind }
    | LCons AggKind AggKind
    | LUnknown


{-| What one element of an aggregate is, written as one character in the wire
format: `Int`, `Float`, `Char`, or any other type.
-}
type AggKind
    = AKInt
    | AKFloat
    | AKChar
    | AKValue


{-| Returns the logical type of `ty`. `ctorShapes` supplies the constructors of a
custom type, and a custom type is described as `LCustom` only when
`customDescFor` accepts it.
-}
monoTypeToLogical : Int -> Mono.LayoutMap (List Mono.CtorShape) -> Mono.MonoType -> LogicalTypeDesc
monoTypeToLogical customMaxFields ctorShapes ty =
    case ty of
        Mono.MInt ->
            LI64

        Mono.MFloat ->
            LF64

        Mono.MChar ->
            LI16

        Mono.MTuple _ [ a, b ] ->
            LTuple2 (kindOf a) (kindOf b)

        Mono.MTuple _ [ a, b, c ] ->
            LTuple3 (kindOf a) (kindOf b) (kindOf c)

        Mono.MRecord _ fields ->
            let
                layout =
                    Types.computeRecordLayout fields
            in
            LRecord (List.map (kindOf << .monoType) layout.fields)

        Mono.MList _ headType ->
            LCons (kindOf headType) AKValue

        Mono.MCustom _ _ _ _ ->
            customDescFor customMaxFields ctorShapes ty

        _ ->
            LValue


{-| Returns `LCustom` for a custom type that has exactly one constructor in
`ctorShapes`, with between one and `customMaxFields` fields, and `LValue` for
any other, including one `ctorShapes` does not know.
-}
customDescFor : Int -> Mono.LayoutMap (List Mono.CtorShape) -> Mono.MonoType -> LogicalTypeDesc
customDescFor customMaxFields ctorShapes ty =
    case Mono.layoutMapGet ty ctorShapes of
        Just [ singleCtor ] ->
            let
                fieldCount =
                    List.length singleCtor.fieldTypes
            in
            if fieldCount > 0 && fieldCount <= customMaxFields then
                LCustom
                    { tag = singleCtor.tag
                    , fields = List.map kindOf singleCtor.fieldTypes
                    }

            else
                LValue

        _ ->
            LValue


{-| Returns the aggregate kind of an element of type `ty`: `AKValue` for anything
but `Int`, `Float` and `Char`, nested aggregates included.
-}
kindOf : Mono.MonoType -> AggKind
kindOf ty =
    case ty of
        Mono.MInt ->
            AKInt

        Mono.MFloat ->
            AKFloat

        Mono.MChar ->
            AKChar

        _ ->
            AKValue


{-| Returns the logical type that an ABI type alone shows: a primitive for
`i64`, `f64`, `i16` and `i1`, and `LUnknown` for any other.
-}
mlirTypeToLogical : MlirType -> LogicalTypeDesc
mlirTypeToLogical mlirType =
    case mlirType of
        I64 ->
            LI64

        F64 ->
            LF64

        I16 ->
            LI16

        I1 ->
            LI1

        _ ->
            LUnknown


{-| Renders a logical type as its wire-format string.
-}
encodeLogicalType : LogicalTypeDesc -> String
encodeLogicalType desc =
    case desc of
        LValue ->
            "value"

        LI64 ->
            "i64"

        LF64 ->
            "f64"

        LI16 ->
            "i16"

        LI1 ->
            "i1"

        LTuple2 a b ->
            "tuple2:" ++ kindChar a ++ ":" ++ kindChar b

        LTuple3 a b c ->
            "tuple3:" ++ kindChar a ++ ":" ++ kindChar b ++ ":" ++ kindChar c

        LRecord fields ->
            "record:"
                ++ String.fromInt (List.length fields)
                ++ String.concat (List.map (\k -> ":" ++ kindChar k) fields)

        LCustom { tag, fields } ->
            "custom:"
                ++ String.fromInt tag
                ++ ":"
                ++ String.fromInt (List.length fields)
                ++ String.concat (List.map (\k -> ":" ++ kindChar k) fields)

        LCons h t ->
            "cons:" ++ kindChar h ++ ":" ++ kindChar t

        LUnknown ->
            "value"


{-| Returns the one-character wire form of an aggregate kind.
-}
kindChar : AggKind -> String
kindChar k =
    case k of
        AKInt ->
            "i"

        AKFloat ->
            "f"

        AKChar ->
            "c"

        AKValue ->
            "v"


{-| Returns `op` with the logical types of `argTypes` and `resultType` attached,
replacing any already there. An op that is not a `func.func` is returned
unchanged.

`ctorShapes` supplies the constructors of each custom type, and a custom type
with more than `customMaxFields` fields is described as `"value"`.

-}
addLogicalTypesAttr : Int -> Mono.LayoutMap (List Mono.CtorShape) -> List Mono.MonoType -> Mono.MonoType -> MlirOp -> MlirOp
addLogicalTypesAttr customMaxFields ctorShapes argTypes resultType op =
    addLogicalDescsAttr
        (List.map (monoTypeToLogical customMaxFields ctorShapes) argTypes)
        (monoTypeToLogical customMaxFields ctorShapes resultType)
        op


{-| Returns `op` with logical types attached for a function known only by its ABI
types, replacing any already there. An `i64`, `f64`, `i16` or `i1` is described
as that primitive and any other type as `"value"`, because an `!eco.value` does
not show which aggregate, if any, it holds. An op that is not a `func.func` is
returned unchanged.
-}
addLogicalTypesAttrUnknown : List MlirType -> MlirType -> MlirOp -> MlirOp
addLogicalTypesAttrUnknown argMlirTypes resultMlirType op =
    addLogicalDescsAttr
        (List.map mlirTypeToLogical argMlirTypes)
        (mlirTypeToLogical resultMlirType)
        op


{-| Returns `op` with `argDescs` and `resultDesc` rendered into its two
logical-type attributes, if it is a `func.func`, and unchanged otherwise.
-}
addLogicalDescsAttr : List LogicalTypeDesc -> LogicalTypeDesc -> MlirOp -> MlirOp
addLogicalDescsAttr argDescs resultDesc op =
    if op.name == "func.func" then
        let
            argEntries =
                List.map (StringAttr << encodeLogicalType) argDescs

            resultEntries =
                [ StringAttr (encodeLogicalType resultDesc) ]
        in
        { op
            | attrs =
                op.attrs
                    |> Dict.insert "eco.logical_param_types"
                        (ArrayAttr Nothing argEntries)
                    |> Dict.insert "eco.logical_result_types"
                        (ArrayAttr Nothing resultEntries)
        }

    else
        op
