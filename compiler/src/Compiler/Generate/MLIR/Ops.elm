module Compiler.Generate.MLIR.Ops exposing
    ( opBuilder, mlirOp, mkRegion, mkRegionTerminatedByOps, funcFunc
    , ecoConstantUnit, ecoConstantEmptyRec, ecoConstantTrue, ecoConstantFalse, ecoConstantNil, ecoConstantNothing, ecoConstantEmptyString, ecoConstantNullCons
    , ecoConstructList, ecoConstructTuple2, ecoConstructTuple3, ecoConstructRecord, ecoConstructCustom
    , ecoProjectListHead, ecoProjectListTail, ecoProjectTuple2, ecoProjectTuple3, ecoProjectRecord, ecoProjectCustom
    , ecoCallNamed, ecoReturn, ecoYield, ecoStringLiteral, ecoUnaryOp, ecoBinaryOp, ecoNullaryOp, ecoTernaryOp, ecoCase, ecoCaseString, ecoGetTag
    , ecoArrayGet, ecoArraySet, ecoArrayLength
    , arithConstantInt, arithConstantInt32, arithConstantFloat, arithConstantBool, arithConstantChar, arithCmpI
    , scfWhile, scfCondition
    , ecoCaseMany, ecoCaseStringMany, ecoYieldMany, scfYieldMany
    , ecoPapCreateGroup, GroupSibling, slotKindsAttr, withSlotKinds, assertStageArity
    , aggCustomType, aggTupleType, ecoCallNamedMulti, ecoFromHeap, ecoGlobal, ecoMakeCustom, ecoMakeTuple2, ecoMakeTuple3, ecoProjectCustomAgg, ecoProjectTuple2Agg, ecoProjectTuple3Agg, ecoReturnMulti, ecoToHeap, funcFuncMulti
    )

{-| The MLIR generator builds every op through this module, so that each op's
name, operand order and attributes are written down in one place.

Each builder takes the generation context and returns it, with a fresh op id
used, together with the op. The ops are in the eco dialect, which holds Elm's
values, heap objects, calls and pattern matches, and in the standard `arith`,
`scf` and `func` dialects.

Almost every op with operands carries an `_operand_types` attribute listing
the operands' types in order; an op with no operands either omits it or
carries an empty list.

Several facts recur across the builders:

  - An Elm value that is not unboxed is an `!eco.value`. The `eco.constant`
    kinds are 0 for False, 1 for True and 2 for the _empty constant_, a single
    value shared by Unit, the empty record, the empty list, `Nothing` and the
    empty string. Any other constructor without fields is an
    `eco.constant.null_cons` carrying its tag.
  - A _slot kind_ says how a field or capture is stored: 0 boxed, 1 Int, 2
    Float, 3 Char, as `Types.mlirTypeToKind` gives it.
  - A _value aggregate_ is a tuple or custom-type value held in SSA values
    rather than on the heap, typed `!eco.tuple2<...>`, `!eco.tuple3<...>` or
    `!eco.custom<...>` by its slot types. `eco.make.*` builds one,
    `eco.to_heap` and `eco.from_heap` move one to and from the heap, and the
    `...Agg` projections read from one.
  - A multi-result `func.func`, with its multi-value `eco.return` and
    multi-result `eco.call`, is how a function returns several values at once.


# Op Builder Plumbing

@docs opBuilder, mlirOp, mkRegion, mkRegionTerminatedByOps, funcFunc


# Eco Constants

@docs ecoConstantUnit, ecoConstantEmptyRec, ecoConstantTrue, ecoConstantFalse, ecoConstantNil, ecoConstantNothing, ecoConstantEmptyString, ecoConstantNullCons


# Eco Constructors

@docs ecoConstructList, ecoConstructTuple2, ecoConstructTuple3, ecoConstructRecord, ecoConstructCustom


# Eco Projections

@docs ecoProjectListHead, ecoProjectListTail, ecoProjectTuple2, ecoProjectTuple3, ecoProjectRecord, ecoProjectCustom


# Eco Operations

@docs ecoCallNamed, ecoReturn, ecoYield, ecoStringLiteral, ecoUnaryOp, ecoBinaryOp, ecoNullaryOp, ecoTernaryOp, ecoCase, ecoCaseString, ecoGetTag


# Eco Array Operations

@docs ecoArrayGet, ecoArraySet, ecoArrayLength


# Arith Operations

@docs arithConstantInt, arithConstantInt32, arithConstantFloat, arithConstantBool, arithConstantChar, arithCmpI


# SCF Operations

@docs scfWhile, scfCondition


# Batch Operations

@docs ecoCaseMany, ecoCaseStringMany, ecoYieldMany, scfYieldMany


# PAP Group Creation

@docs ecoPapCreateGroup, GroupSibling, slotKindsAttr, withSlotKinds, assertStageArity


# Value Aggregates, Multi-Result Functions and Globals

@docs aggCustomType, aggTupleType, ecoCallNamedMulti, ecoFromHeap, ecoGlobal, ecoMakeCustom, ecoMakeTuple2, ecoMakeTuple3, ecoProjectCustomAgg, ecoProjectTuple2Agg, ecoProjectTuple3Agg, ecoReturnMulti, ecoToHeap, funcFuncMulti

-}

import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Dict
import Mlir.Mlir as Mlir
    exposing
        ( MlirAttr(..)
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        , Visibility(..)
        )
import OrderedDict
import Utils.Crash exposing (crash)



-- ====== OP BUILDER PLUMBING ======


{-| The `Mlir.Mlir` op builder functions, re-exported so that callers chain
`withOperands`, `withAttrs` and the rest without importing `Mlir.Mlir`.
-}
opBuilder : Mlir.OpBuilderFns e
opBuilder =
    Mlir.opBuilder


{-| Starts building an op called by the given name, taking a fresh op id from
the context.
-}
mlirOp : Ctx.Context -> String -> Mlir.OpBuilder Ctx.Context
mlirOp env =
    Mlir.mlirOp (\e -> Ctx.freshOpId e |> (\( id, ctx ) -> ( ctx, id ))) env



-- ====== ECO CONSTANTS ======


{-| Builds the empty constant for Unit.
-}
ecoConstantUnit : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantUnit ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Builds the empty constant for the empty record.
-}
ecoConstantEmptyRec : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmptyRec ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Builds the `eco.constant` for True, kind 1, as an `!eco.value`.
-}
ecoConstantTrue : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantTrue ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 1))
        |> opBuilder.build


{-| Builds the `eco.constant` for False, kind 0, as an `!eco.value`.
-}
ecoConstantFalse : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantFalse ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 0))
        |> opBuilder.build


{-| Builds the empty constant for the empty list.
-}
ecoConstantNil : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantNil ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Builds the empty constant for `Nothing`.
-}
ecoConstantNothing : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantNothing ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Builds the empty constant for the empty string.
-}
ecoConstantEmptyString : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmptyString ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Builds the empty constant: an `eco.constant` of kind 2.
-}
ecoConstantEmpty : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmpty ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 2))
        |> opBuilder.build


{-| Builds the `eco.constant.null_cons` for a nullary constructor whose tag is
`tag`, as an `!eco.value`.

Nothing here checks the tag against the range the embedded word can hold.

-}
ecoConstantNullCons : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
ecoConstantNullCons ctx resultVar tag =
    mlirOp ctx "eco.constant.null_cons"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "tag" (IntAttr Nothing tag))
        |> opBuilder.build



-- ====== ECO CONSTRUCTION ======


{-| Builds an `eco.construct.list` cons cell from a head and a tail.

When `headUnboxed` is true, `head_kind` is the slot kind of the head's type;
otherwise it is 0, boxed.

-}
ecoConstructList : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Bool -> ( Ctx.Context, MlirOp )
ecoConstructList ctx resultVar ( headVar, headType ) ( tailVar, tailType ) headUnboxed =
    let
        headKind =
            if headUnboxed then
                Types.mlirTypeToKind headType

            else
                0

        attrs =
            Dict.fromList
                [ ( "_operand_types"
                  , ArrayAttr Nothing
                        [ TypeAttr headType, TypeAttr tailType ]
                  )
                , ( "head_unboxed", BoolAttr headUnboxed )
                , ( "head_kind", IntAttr Nothing headKind )
                ]
    in
    mlirOp ctx "eco.construct.list"
        |> opBuilder.withOperands [ headVar, tailVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.construct.tuple2` heap tuple. The last argument becomes the
`unboxed_bitmap` attribute unchanged.
-}
ecoConstructTuple2 : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Ctx.Context, MlirOp )
ecoConstructTuple2 ctx resultVar ( aVar, aType ) ( bVar, bType ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types"
                  , ArrayAttr Nothing
                        [ TypeAttr aType, TypeAttr bType ]
                  )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple2"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.construct.tuple3` heap tuple. The last argument becomes the
`unboxed_bitmap` attribute unchanged.
-}
ecoConstructTuple3 : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Ctx.Context, MlirOp )
ecoConstructTuple3 ctx resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types"
                  , ArrayAttr Nothing
                        [ TypeAttr aType, TypeAttr bType, TypeAttr cType ]
                  )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple3"
        |> opBuilder.withOperands [ aVar, bVar, cVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.construct.record` heap record from its field operands in
layout order.

`slotKinds` holds one slot kind per field and becomes `slot_kinds`. It crashes
the compile when `slotKinds` does not have `fieldCount` entries.

-}
ecoConstructRecord : Ctx.Context -> String -> List ( String, MlirType ) -> Int -> List Int -> ( Ctx.Context, MlirOp )
ecoConstructRecord ctx resultVar fieldPairs fieldCount slotKinds =
    let
        allOperands =
            List.map Tuple.first fieldPairs

        allTypes =
            List.map Tuple.second fieldPairs

        operandTypesAttr =
            if List.isEmpty allOperands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr allTypes))

        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    [ ( "field_count", IntAttr Nothing fieldCount )
                    , ( "slot_kinds", slotKindListAttr (checkKindsLength "eco.construct.record" fieldCount slotKinds) )
                    ]
                )
    in
    mlirOp ctx "eco.construct.record"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.construct.custom` heap value with constructor tag `tag` and
`size` fields, from the field operands.

`slotKinds` holds one slot kind per field and becomes `slot_kinds`; it crashes
the compile when `slotKinds` does not have `size` entries. A constructor name,
when given, becomes the `constructor` attribute.

-}
ecoConstructCustom : Ctx.Context -> String -> Int -> Int -> List Int -> List ( String, MlirType ) -> Maybe String -> ( Ctx.Context, MlirOp )
ecoConstructCustom ctx resultVar tag size slotKinds operands maybeCtorName =
    let
        allOperands =
            List.map Tuple.first operands

        allTypes =
            List.map Tuple.second operands

        operandTypesAttr =
            if List.isEmpty allOperands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr allTypes))

        constructorAttr =
            case maybeCtorName of
                Just name ->
                    Dict.singleton "constructor" (StringAttr name)

                Nothing ->
                    Dict.empty

        attrs =
            Dict.union operandTypesAttr
                (Dict.union constructorAttr
                    (Dict.fromList
                        [ ( "tag", IntAttr Nothing tag )
                        , ( "size", IntAttr Nothing size )
                        , ( "slot_kinds", slotKindListAttr (checkKindsLength "eco.construct.custom" size slotKinds) )
                        ]
                    )
                )
    in
    mlirOp ctx "eco.construct.custom"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Returns `kinds` unchanged when it has `count` entries, and otherwise crashes
the compile with a message naming `opName`.
-}
checkKindsLength : String -> Int -> List Int -> List Int
checkKindsLength opName count kinds =
    if List.length kinds == count then
        kinds

    else
        crash
            (opName
                ++ ": slot_kinds has "
                ++ String.fromInt (List.length kinds)
                ++ " entries for "
                ++ String.fromInt count
                ++ " slots"
            )



-- ====== ECO PROJECTION ======


{-| Builds an `eco.project.list_head` reading the head of a cons cell at
`resultType`.
-}
ecoProjectListHead : Ctx.Context -> String -> MlirType -> String -> ( Ctx.Context, MlirOp )
ecoProjectListHead ctx resultVar resultType listVar =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])
    in
    mlirOp ctx "eco.project.list_head"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.list_tail` reading the tail of a cons cell.
-}
ecoProjectListTail : Ctx.Context -> String -> String -> ( Ctx.Context, MlirOp )
ecoProjectListTail ctx resultVar listVar =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])
    in
    mlirOp ctx "eco.project.list_tail"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.tuple2` reading field `field` of a heap 2-tuple at
`resultType`.
-}
ecoProjectTuple2 : Ctx.Context -> String -> Int -> MlirType -> String -> ( Ctx.Context, MlirOp )
ecoProjectTuple2 ctx resultVar field resultType tupleVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr Types.ecoValue ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple2"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.tuple3` reading field `field` of a heap 3-tuple at
`resultType`.
-}
ecoProjectTuple3 : Ctx.Context -> String -> Int -> MlirType -> String -> ( Ctx.Context, MlirOp )
ecoProjectTuple3 ctx resultVar field resultType tupleVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr Types.ecoValue ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple3"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build



-- ====== VALUE-AGGREGATE OPS ======


{-| Returns the text of one slot type inside a value aggregate type: the type's
own name for an integer or float type, `!` followed by the name for a named
type, and `!eco.value` for a function type.
-}
aggSlotTypeString : MlirType -> String
aggSlotTypeString ty =
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
            "!" ++ s

        FunctionType _ ->
            -- A closure in a slot is an !eco.value.
            "!eco.value"


{-| Returns the value tuple type for the given slot types, such as
`!eco.tuple2<i64, !eco.value>`.

Three slot types give `!eco.tuple3`; any other number gives `!eco.tuple2`.

-}
aggTupleType : List MlirType -> MlirType
aggTupleType elemTypes =
    let
        arity =
            if List.length elemTypes == 3 then
                "eco.tuple3<"

            else
                "eco.tuple2<"
    in
    NamedStruct (arity ++ String.join ", " (List.map aggSlotTypeString elemTypes) ++ ">")


{-| Builds an `eco.make.tuple2`: a value-level 2-tuple, typed by `aggTupleType`
of its operand types.
-}
ecoMakeTuple2 : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoMakeTuple2 ctx resultVar ( aVar, aType ) ( bVar, bType ) =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr aType, TypeAttr bType ])
    in
    mlirOp ctx "eco.make.tuple2"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resultVar, aggTupleType [ aType, bType ] ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.make.tuple3`: a value-level 3-tuple, typed by `aggTupleType`
of its operand types.
-}
ecoMakeTuple3 : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoMakeTuple3 ctx resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr aType, TypeAttr bType, TypeAttr cType ])
    in
    mlirOp ctx "eco.make.tuple3"
        |> opBuilder.withOperands [ aVar, bVar, cVar ]
        |> opBuilder.withResults [ ( resultVar, aggTupleType [ aType, bType, cType ] ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Returns the value custom type for the given slot types, such as
`!eco.custom<i64, !eco.value>`. The constructor tag is not part of the type.
-}
aggCustomType : List MlirType -> MlirType
aggCustomType slotTypes =
    NamedStruct ("eco.custom<" ++ String.join ", " (List.map aggSlotTypeString slotTypes) ++ ">")


{-| Builds an `eco.make.custom`: a value-level custom-type value with tag `tag`,
typed by `aggCustomType` of its operand types.

It carries `tag` and, when given, `constructor`, like `eco.construct.custom`,
but no `size` or `slot_kinds`.

-}
ecoMakeCustom : Ctx.Context -> String -> Int -> Maybe String -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoMakeCustom ctx resultVar tag maybeCtorName operands =
    let
        baseAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands) )
                , ( "tag", IntAttr Nothing tag )
                ]

        attrs =
            case maybeCtorName of
                Just n ->
                    Dict.insert "constructor" (StringAttr n) baseAttrs

                Nothing ->
                    baseAttrs
    in
    mlirOp ctx "eco.make.custom"
        |> opBuilder.withOperands (List.map Tuple.first operands)
        |> opBuilder.withResults [ ( resultVar, aggCustomType (List.map Tuple.second operands) ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.custom` reading field `fieldIndex` of a value-level
custom-type value. Its `_operand_types` names the aggregate type, as for
`ecoProjectTuple2Agg`.
-}
ecoProjectCustomAgg : Ctx.Context -> String -> Int -> MlirType -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoProjectCustomAgg ctx resultVar fieldIndex resultType ( containerVar, containerType ) =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr containerType ] )
                , ( "field_index", IntAttr Nothing fieldIndex )
                ]
    in
    mlirOp ctx "eco.project.custom"
        |> opBuilder.withOperands [ containerVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.tuple2` reading field `field` of a value-level
2-tuple.

The op name is the heap form's; what differs is that `_operand_types` names the
aggregate type rather than `!eco.value`, and it must do so for the op to be
read as a projection from an aggregate.

-}
ecoProjectTuple2Agg : Ctx.Context -> String -> Int -> MlirType -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoProjectTuple2Agg ctx resultVar field resultType ( tupleVar, tupleType ) =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr tupleType ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple2"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.tuple3` reading field `field` of a value-level
3-tuple, with `_operand_types` naming the aggregate type as for
`ecoProjectTuple2Agg`.
-}
ecoProjectTuple3Agg : Ctx.Context -> String -> Int -> MlirType -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoProjectTuple3Agg ctx resultVar field resultType ( tupleVar, tupleType ) =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr tupleType ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple3"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.record` reading the field at layout index
`fieldIndex` of a heap record at `resultType`.
-}
ecoProjectRecord : Ctx.Context -> String -> Int -> MlirType -> String -> ( Ctx.Context, MlirOp )
ecoProjectRecord ctx resultVar fieldIndex resultType recordVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr Types.ecoValue ] )
                , ( "field_index", IntAttr Nothing fieldIndex )
                ]
    in
    mlirOp ctx "eco.project.record"
        |> opBuilder.withOperands [ recordVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.project.custom` reading field `fieldIndex` of a heap
custom-type value at `resultType`.
-}
ecoProjectCustom : Ctx.Context -> String -> Int -> MlirType -> String -> ( Ctx.Context, MlirOp )
ecoProjectCustom ctx resultVar fieldIndex resultType containerVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr Types.ecoValue ] )
                , ( "field_index", IntAttr Nothing fieldIndex )
                ]
    in
    mlirOp ctx "eco.project.custom"
        |> opBuilder.withOperands [ containerVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build



-- ====== ECO CALLS ======


{-| Returns whether `KernelFacts` lists the callee symbol as droppable. A symbol
it does not list, which includes every non-kernel symbol, answers False.
-}
calleeIsDroppable : String -> Bool
calleeIsDroppable funcName =
    KernelFacts.lookupSymbol funcName
        |> Maybe.map KernelFacts.droppable
        |> Maybe.withDefault False


{-| Builds an `eco.call` to the function named `funcName` with a single result.

When `funcName` starts with `Elm_Kernel_` or `Eco_Kernel_`, the returned context
also records it as a kernel declaration through `Ctx.registerKernelCall`, with
the operand types and `returnType` as its ABI. The `eco.cse_safe` attribute is
added when `callPurityAttrs` is on in the context's config and the callee is
droppable by `KernelFacts`.

-}
ecoCallNamed : Ctx.Context -> String -> String -> List ( String, MlirType ) -> MlirType -> ( Ctx.Context, MlirOp )
ecoCallNamed ctx resultVar funcName operands returnType =
    let
        ctxWithKernel =
            if String.startsWith "Elm_Kernel_" funcName || String.startsWith "Eco_Kernel_" funcName then
                Ctx.registerKernelCall ctx funcName (List.map Tuple.second operands) returnType

            else
                ctx

        allOperands =
            List.map Tuple.first operands

        allTypes =
            List.map Tuple.second operands

        operandTypesAttr =
            if List.isEmpty allOperands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr allTypes))

        csePurityAttr =
            if ctx.ecoConfig.callPurityAttrs && calleeIsDroppable funcName then
                Dict.singleton "eco.cse_safe" UnitAttr

            else
                Dict.empty

        attrs =
            Dict.union csePurityAttr
                (Dict.union operandTypesAttr
                    (Dict.singleton "callee" (SymbolRefAttr funcName))
                )
    in
    mlirOp ctxWithKernel "eco.call"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults [ ( resultVar, returnType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.return` terminator returning one value.
-}
ecoReturn : Ctx.Context -> String -> MlirType -> ( Ctx.Context, MlirOp )
ecoReturn ctx operand operandType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr operandType ])
    in
    mlirOp ctx "eco.return"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| Builds an `eco.return` terminator returning several values: the terminator
of a multi-result function built by `funcFuncMulti`.
-}
ecoReturnMulti : Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoReturnMulti ctx operandPairs =
    let
        attrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing (List.map (TypeAttr << Tuple.second) operandPairs))
    in
    mlirOp ctx "eco.return"
        |> opBuilder.withOperands (List.map Tuple.first operandPairs)
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| Builds an `eco.call` to the function named `funcName` with one result per
pair in the first list, as used to call a multi-result function built by
`funcFuncMulti`.

It adds `eco.cse_safe` under the same conditions as `ecoCallNamed`, but unlike
`ecoCallNamed` it never records a kernel declaration.

-}
ecoCallNamedMulti : Ctx.Context -> List ( String, MlirType ) -> String -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoCallNamedMulti ctx resultPairs funcName operands =
    let
        allOperands =
            List.map Tuple.first operands

        allTypes =
            List.map Tuple.second operands

        operandTypesAttr =
            if List.isEmpty allOperands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr allTypes))

        csePurityAttr =
            if ctx.ecoConfig.callPurityAttrs && calleeIsDroppable funcName then
                Dict.singleton "eco.cse_safe" UnitAttr

            else
                Dict.empty

        attrs =
            Dict.union csePurityAttr
                (Dict.union operandTypesAttr
                    (Dict.singleton "callee" (SymbolRefAttr funcName))
                )
    in
    mlirOp ctx "eco.call"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults resultPairs
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.to_heap`, which allocates a heap object holding a value
aggregate and gives it as an `!eco.value`.
-}
ecoToHeap : Ctx.Context -> String -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoToHeap ctx resultVar ( aggVar, aggType ) =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr aggType ])
    in
    mlirOp ctx "eco.to_heap"
        |> opBuilder.withOperands [ aggVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.from_heap`, which reads a heap object, given as an
`!eco.value`, into a value aggregate of type `aggType`.
-}
ecoFromHeap : Ctx.Context -> String -> MlirType -> String -> ( Ctx.Context, MlirOp )
ecoFromHeap ctx resultVar aggType operandVar =
    mlirOp ctx "eco.from_heap"
        |> opBuilder.withOperands [ operandVar ]
        |> opBuilder.withResults [ ( resultVar, aggType ) ]
        |> opBuilder.withAttrs (Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ]))
        |> opBuilder.build


{-| Builds an `eco.yield` terminator yielding one value from an `eco.case`
alternative.
-}
ecoYield : Ctx.Context -> String -> MlirType -> ( Ctx.Context, MlirOp )
ecoYield ctx operand operandType =
    ecoYieldMany ctx [ ( operand, operandType ) ]


{-| Builds an `eco.yield` terminator yielding any number of values, none
included, from an `eco.case` alternative.
-}
ecoYieldMany : Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoYieldMany ctx operands =
    let
        ( names, types ) =
            List.unzip operands

        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing (List.map TypeAttr types))
    in
    mlirOp ctx "eco.yield"
        |> opBuilder.withOperands names
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| Builds an `eco.string_literal` holding `value`, as an `!eco.value`.
-}
ecoStringLiteral : Ctx.Context -> String -> String -> ( Ctx.Context, MlirOp )
ecoStringLiteral ctx resultVar value =
    mlirOp ctx "eco.string_literal"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (StringAttr value))
        |> opBuilder.build



-- ====== ARITH DIALECT ======


{-| Builds an `i64` `arith.constant`.
-}
arithConstantInt : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
arithConstantInt ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I64 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I64) value))
        |> opBuilder.build


{-| Builds an `i32` `arith.constant`.
-}
arithConstantInt32 : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
arithConstantInt32 ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I32 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) value))
        |> opBuilder.build


{-| Builds an `arith.cmpi` comparing two integers by the predicate named
`predicateName` (`eq`, `ne`, `slt`, `sle`, `sgt`, `sge`, `ult`, `ule`, `ugt` or
`uge`), with an `i1` result.

An unrecognised predicate name is emitted as `eq`. Both entries of
`_operand_types` are the left operand's type.

-}
arithCmpI : Ctx.Context -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
arithCmpI ctx predicateName resultVar ( lhs, lhsTy ) ( rhs, _ ) =
    let
        predicateValue =
            case predicateName of
                "eq" ->
                    0

                "ne" ->
                    1

                "slt" ->
                    2

                "sle" ->
                    3

                "sgt" ->
                    4

                "sge" ->
                    5

                "ult" ->
                    6

                "ule" ->
                    7

                "ugt" ->
                    8

                "uge" ->
                    9

                _ ->
                    0

        attrs =
            Dict.fromList
                [ ( "predicate", IntAttr (Just I64) predicateValue )
                , ( "_operand_types", ArrayAttr Nothing [ TypeAttr lhsTy, TypeAttr lhsTy ] )
                ]
    in
    mlirOp ctx "arith.cmpi"
        |> opBuilder.withOperands [ lhs, rhs ]
        |> opBuilder.withResults [ ( resultVar, I1 ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `f64` `arith.constant`.
-}
arithConstantFloat : Ctx.Context -> String -> Float -> ( Ctx.Context, MlirOp )
arithConstantFloat ctx resultVar value =
    let
        valueAttr =
            TypedFloatAttr value F64
    in
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, F64 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" valueAttr)
        |> opBuilder.build


{-| Builds an `i1` `arith.constant`.
-}
arithConstantBool : Ctx.Context -> String -> Bool -> ( Ctx.Context, MlirOp )
arithConstantBool ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I1 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (BoolAttr value))
        |> opBuilder.build


{-| Builds an `arith.constant` of the unboxed Char type holding `codepoint`.
-}
arithConstantChar : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
arithConstantChar ctx resultVar codepoint =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoChar ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just Types.ecoChar) codepoint))
        |> opBuilder.build



-- ====== ECO OPERATORS ======


{-| Builds the eco op named `opName`, such as `eco.int.negate`, with one
operand.
-}
ecoUnaryOp : Ctx.Context -> String -> String -> ( String, MlirType ) -> MlirType -> ( Ctx.Context, MlirOp )
ecoUnaryOp ctx opName resultVar ( operand, operandTy ) resultTy =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr operandTy ])
    in
    mlirOp ctx opName
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withResults [ ( resultVar, resultTy ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds the eco op named `opName`, such as `eco.int.add`, with two operands.
-}
ecoBinaryOp : Ctx.Context -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> MlirType -> ( Ctx.Context, MlirOp )
ecoBinaryOp ctx opName resultVar ( lhs, lhsTy ) ( rhs, rhsTy ) resultTy =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr lhsTy, TypeAttr rhsTy ])
    in
    mlirOp ctx opName
        |> opBuilder.withOperands [ lhs, rhs ]
        |> opBuilder.withResults [ ( resultVar, resultTy ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds the eco op named `opName`, such as `eco.array.empty`, with no
operands and no attributes.
-}
ecoNullaryOp : Ctx.Context -> String -> String -> MlirType -> ( Ctx.Context, MlirOp )
ecoNullaryOp ctx opName resultVar resultTy =
    mlirOp ctx opName
        |> opBuilder.withResults [ ( resultVar, resultTy ) ]
        |> opBuilder.build


{-| Builds the eco op named `opName`, such as `eco.array.slice`, with three
operands.
-}
ecoTernaryOp :
    Ctx.Context
    -> String
    -> String
    -> ( String, MlirType )
    -> ( String, MlirType )
    -> ( String, MlirType )
    -> MlirType
    -> ( Ctx.Context, MlirOp )
ecoTernaryOp ctx opName resultVar ( a, aTy ) ( b, bTy ) ( c, cTy ) resultTy =
    let
        attrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr aTy, TypeAttr bTy, TypeAttr cTy ])
    in
    mlirOp ctx opName
        |> opBuilder.withOperands [ a, b, c ]
        |> opBuilder.withResults [ ( resultVar, resultTy ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.array.get` reading the element at an `i64` index at
`elementType`.
-}
ecoArrayGet : Ctx.Context -> String -> String -> String -> MlirType -> ( Ctx.Context, MlirOp )
ecoArrayGet ctx resultVar arrayVar indexVar elementType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue, TypeAttr I64 ])
    in
    mlirOp ctx "eco.array.get"
        |> opBuilder.withOperands [ arrayVar, indexVar ]
        |> opBuilder.withResults [ ( resultVar, elementType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.array.set`, whose result is an array with the element at an
`i64` index set to the value.
-}
ecoArraySet : Ctx.Context -> String -> String -> String -> String -> MlirType -> ( Ctx.Context, MlirOp )
ecoArraySet ctx resultVar arrayVar indexVar valueVar valueType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue, TypeAttr I64, TypeAttr valueType ])
    in
    mlirOp ctx "eco.array.set"
        |> opBuilder.withOperands [ arrayVar, indexVar, valueVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.array.length`, with an `i64` result.
-}
ecoArrayLength : Ctx.Context -> String -> String -> ( Ctx.Context, MlirOp )
ecoArrayLength ctx resultVar arrayVar =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])
    in
    mlirOp ctx "eco.array.length"
        |> opBuilder.withOperands [ arrayVar ]
        |> opBuilder.withResults [ ( resultVar, I64 ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build



-- ====== REGIONS AND FUNCTIONS ======


{-| Returns a region with a single block: its arguments, its body ops and its
terminator.
-}
mkRegion : List ( String, MlirType ) -> List MlirOp -> MlirOp -> MlirRegion
mkRegion args body terminator =
    MlirRegion
        { entry =
            { args = args
            , body = body
            , terminator = terminator
            }
        , blocks = OrderedDict.empty
        }


{-| Returns a single-block region whose terminator is the last of `ops` and
whose body is the rest.

It crashes the compile when `ops` is empty.

-}
mkRegionTerminatedByOps : List ( String, MlirType ) -> List MlirOp -> MlirRegion
mkRegionTerminatedByOps args ops =
    case List.reverse ops of
        [] ->
            crash "mkRegionTerminatedByOps: empty ops list - must have terminator"

        terminator :: restReversed ->
            MlirRegion
                { entry =
                    { args = args
                    , body = List.reverse restReversed
                    , terminator = terminator
                    }
                , blocks = OrderedDict.empty
                }


{-| Builds an `eco.global` named `symName`: a module-level slot that holds one
value for the whole run, used to memoise a top-level value. It has no
operands, results or regions.
-}
ecoGlobal : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoGlobal ctx symName =
    mlirOp ctx "eco.global"
        |> opBuilder.withAttrs (Dict.fromList [ ( "sym_name", StringAttr symName ) ])
        |> opBuilder.build


{-| Builds a private `func.func` named `funcName` with a single result of type
`returnType`.
-}
funcFunc : Ctx.Context -> String -> List ( String, MlirType ) -> MlirType -> MlirRegion -> ( Ctx.Context, MlirOp )
funcFunc ctx funcName args returnType bodyRegion =
    let
        attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr funcName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = List.map Tuple.second args
                            , results = [ returnType ]
                            }
                        )
                  )
                ]
    in
    mlirOp ctx "func.func"
        |> opBuilder.withRegions [ bodyRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds a private `func.func` named `funcName` with one result per entry of
`resultTypes`.
-}
funcFuncMulti : Ctx.Context -> String -> List ( String, MlirType ) -> List MlirType -> MlirRegion -> ( Ctx.Context, MlirOp )
funcFuncMulti ctx funcName args resultTypes bodyRegion =
    let
        attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr funcName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = List.map Tuple.second args
                            , results = resultTypes
                            }
                        )
                  )
                ]
    in
    mlirOp ctx "func.func"
        |> opBuilder.withRegions [ bodyRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build



-- ====== CONTROL FLOW ======


{-| Builds an `eco.case` with a single result.

See `ecoCaseMany`, which this calls with a one-element result list.

-}
ecoCase : Ctx.Context -> String -> String -> MlirType -> String -> List Int -> List MlirRegion -> MlirType -> ( Ctx.Context, MlirOp )
ecoCase ctx resultVar scrutinee scrutineeType caseKind tags regions resultType =
    ecoCaseMany ctx scrutinee scrutineeType caseKind tags regions [ ( resultVar, resultType ) ]


{-| Builds an `eco.case` over a string with a single result.

See `ecoCaseStringMany`, which this calls with a one-element result list.

-}
ecoCaseString : Ctx.Context -> String -> String -> MlirType -> List Int -> List String -> List MlirRegion -> MlirType -> ( Ctx.Context, MlirOp )
ecoCaseString ctx resultVar scrutinee scrutineeType tags stringPatterns regions resultType =
    ecoCaseStringMany ctx scrutinee scrutineeType tags stringPatterns regions [ ( resultVar, resultType ) ]


{-| Builds an `eco.case` that selects one of `regions` by the scrutinee and
produces the values listed in `results`.

`caseKind` becomes the `case_kind` attribute (for example `ctor`, `int`, `chr`,
`str` or `bool`) and `tags` the `tags` attribute, one per region. `eco.case` is
not a terminator: it produces values, and each region must end in an
`eco.yield` of values matching `results`.

-}
ecoCaseMany : Ctx.Context -> String -> MlirType -> String -> List Int -> List MlirRegion -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoCaseMany ctx scrutinee scrutineeType caseKind tags regions results =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr scrutineeType ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                , ( "case_kind", StringAttr caseKind )
                ]
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withResults results
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.case` of kind `str` that matches a string scrutinee and
produces the values listed in `results`.

`stringPatterns` becomes the `string_patterns` attribute, one string for each
region but the last, which is the default. `eco.case` is not a terminator: each
region must end in an `eco.yield` of values matching `results`.

-}
ecoCaseStringMany : Ctx.Context -> String -> MlirType -> List Int -> List String -> List MlirRegion -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoCaseStringMany ctx scrutinee scrutineeType tags stringPatterns regions results =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr scrutineeType ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                , ( "case_kind", StringAttr "str" )
                , ( "string_patterns", ArrayAttr Nothing (List.map StringAttr stringPatterns) )
                ]
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withResults results
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `eco.get_tag` reading the constructor tag of an `!eco.value` as an
`i32`.
-}
ecoGetTag : Ctx.Context -> String -> String -> ( Ctx.Context, MlirOp )
ecoGetTag ctx resultVar operand =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])
    in
    mlirOp ctx "eco.get_tag"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withResults [ ( resultVar, I32 ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds an `scf.yield` terminator yielding any number of values, none
included.
-}
scfYieldMany : Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
scfYieldMany ctx operands =
    let
        ( names, types ) =
            List.unzip operands

        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing (List.map TypeAttr types))
    in
    mlirOp ctx "scf.yield"
        |> opBuilder.withOperands names
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| Builds an `scf.while` loop. Each triple names a loop result, its initial
value and their type.

The "before" region computes the condition and ends in `scfCondition`; the
"after" region is the loop body and ends in an `scf.yield` of the next
iteration's values.

-}
scfWhile :
    Ctx.Context
    -> List ( String, String, MlirType ) -- (resultVar, initVar, type) triples
    -> MlirRegion -- "before" region (condition), ends with scf.condition
    -> MlirRegion -- "after" region (body), ends with scf.yield
    -> ( Ctx.Context, MlirOp )
scfWhile ctx loopVars beforeRegion afterRegion =
    let
        initVars =
            List.map (\( _, initVar, _ ) -> initVar) loopVars

        results =
            List.map (\( resultVar, _, t ) -> ( resultVar, t )) loopVars

        argTypes =
            List.map (\( _, _, t ) -> t) loopVars

        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing (List.map TypeAttr argTypes))
    in
    mlirOp ctx "scf.while"
        |> opBuilder.withOperands initVars
        |> opBuilder.withResults results
        |> opBuilder.withRegions [ beforeRegion, afterRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Builds the `scf.condition` terminator of an `scf.while` "before" region.

When `condVar` is true the loop continues into the "after" region with `args`;
when it is false the loop ends and `args` become its results.

-}
scfCondition : Ctx.Context -> String -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
scfCondition ctx condVar args =
    let
        argVars =
            List.map Tuple.first args

        argTypes =
            List.map Tuple.second args

        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing (TypeAttr I1 :: List.map TypeAttr argTypes))
    in
    mlirOp ctx "scf.condition"
        |> opBuilder.withOperands (condVar :: argVars)
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build



-- ====== CLOSURE KINDS AND LIMITS ======


{-| Returns the slot kinds of the given types, one per type by
`Types.mlirTypeToKind`, as a dense `i8` array attribute.
-}
slotKindsAttr : List MlirType -> MlirAttr
slotKindsAttr tys =
    slotKindListAttr (List.map Types.mlirTypeToKind tys)


{-| Returns a list of slot kinds as a dense `i8` array attribute.
-}
slotKindListAttr : List Int -> MlirAttr
slotKindListAttr kinds =
    ArrayAttr (Just I8) (List.map (IntAttr Nothing) kinds)


{-| Returns `attrs` with `slot_kinds` set to `slotKindsAttr tys`, or unchanged
when `tys` is empty.
-}
withSlotKinds : List MlirType -> Dict.Dict String MlirAttr -> Dict.Dict String MlirAttr
withSlotKinds tys attrs =
    if List.isEmpty tys then
        attrs

    else
        Dict.insert "slot_kinds" (slotKindsAttr tys) attrs


{-| Returns `arity` unchanged, and crashes the compile with an internal compiler
error when it exceeds `HeapLimits.maxStageArity`.
-}
assertStageArity : Int -> Int
assertStageArity arity =
    if arity > HeapLimits.maxStageArity then
        crash
            ("internal compiler error: closure stage arity "
                ++ String.fromInt arity
                ++ " > "
                ++ String.fromInt HeapLimits.maxStageArity
                ++ " reached the generator (validated by ValidateLimits)"
            )

    else
        arity



-- ====== ECO papCreateGroup ======


{-| One closure of an `eco.papCreateGroup`: what `ecoPapCreateGroup` needs to
describe it.

`slotKinds` gives the types whose slot kinds describe the closure's slots.
`resultKind` is the slot-kind code of the function's saturated result: 0 for a
boxed result, 1 Int, 2 Float, 3 Char. `numCaptured` and the length of
`captureVars` are emitted as separate attributes, and nothing here makes them
agree.

-}
type alias GroupSibling =
    { functionName : String
    , fastEvaluator : String
    , arity : Int
    , numCaptured : Int
    , slotKinds : List MlirType
    , resultKind : Int
    , captureVars : List String
    , captureTypes : List MlirType
    }


{-| Builds one `eco.papCreateGroup` that creates a group of sibling closures
together, for mutually recursive local functions, binding them to `resultVars`
in sibling order.

`siblings` are in sibling-index order. Each `crossEdges` triple is
`(producer, consumer, slot)`, sibling indices and a slot index into the
consumer's captured values, emitted flattened as `cross_edges`. Every
sibling's captured values become the op's operands, concatenated in sibling
order. `_result_kinds` is emitted only when some sibling's `resultKind` is not
0, and every sibling's arity goes through `assertStageArity`.

-}
ecoPapCreateGroup :
    Ctx.Context
    -> List GroupSibling
    -> List ( Int, Int, Int )
    -> List String
    -> ( Ctx.Context, MlirOp )
ecoPapCreateGroup ctx siblings crossEdges resultVars =
    let
        functions =
            siblings |> List.map (.functionName >> SymbolRefAttr) |> ArrayAttr Nothing

        fastEvaluators =
            siblings |> List.map (.fastEvaluator >> SymbolRefAttr) |> ArrayAttr Nothing

        -- An array of i64 attributes, not `ArrayAttr (Just I64)`, which is the
        -- dense array form these attributes are not declared as.
        i64Array ints =
            ArrayAttr Nothing (List.map (\i -> IntAttr (Just I64) i) ints)

        arities =
            siblings |> List.map (.arity >> assertStageArity) |> i64Array

        numCaptured =
            siblings |> List.map .numCaptured |> i64Array

        slotKinds =
            siblings |> List.map (.slotKinds >> slotKindsAttr) |> ArrayAttr Nothing

        anyPrimitiveResult =
            List.any (\s -> s.resultKind /= 0) siblings

        resultKindsAttrs =
            if anyPrimitiveResult then
                Dict.singleton "_result_kinds"
                    (siblings |> List.map .resultKind |> i64Array)

            else
                Dict.empty

        captureCounts =
            siblings |> List.map (.captureVars >> List.length) |> i64Array

        flatCrossEdges =
            crossEdges
                |> List.concatMap (\( p, c, s ) -> [ p, c, s ])
                |> i64Array

        captureVars =
            List.concatMap .captureVars siblings

        captureTypes =
            List.concatMap .captureTypes siblings

        operandVars =
            captureVars

        operandTypes =
            captureTypes

        operandTypesAttr =
            if List.isEmpty operandTypes then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr operandTypes))

        attrs =
            Dict.union resultKindsAttrs
                (Dict.union operandTypesAttr
                    (Dict.fromList
                        [ ( "functions", functions )
                        , ( "fast_evaluators", fastEvaluators )
                        , ( "arities", arities )
                        , ( "num_captured", numCaptured )
                        , ( "slot_kinds", slotKinds )
                        , ( "capture_counts", captureCounts )
                        , ( "cross_edges", flatCrossEdges )
                        ]
                    )
                )

        results =
            List.map (\v -> ( v, Types.ecoValue )) resultVars
    in
    mlirOp ctx "eco.papCreateGroup"
        |> opBuilder.withOperands operandVars
        |> opBuilder.withResults results
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
