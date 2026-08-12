module Compiler.Generate.MLIR.Ops exposing
    ( opBuilder, mlirOp, mkRegion, mkRegionTerminatedByOps, funcFunc
    , ecoConstantUnit, ecoConstantEmptyRec, ecoConstantTrue, ecoConstantFalse, ecoConstantNil, ecoConstantNothing, ecoConstantEmptyString
    , ecoConstructList, ecoConstructTuple2, ecoConstructTuple3, ecoConstructRecord, ecoConstructCustom
    , ecoProjectListHead, ecoProjectListTail, ecoProjectTuple2, ecoProjectTuple3, ecoProjectRecord, ecoProjectCustom
    , ecoCallNamed, ecoReturn, ecoYield, ecoStringLiteral, ecoUnaryOp, ecoBinaryOp, ecoNullaryOp, ecoTernaryOp, ecoCase, ecoCaseString, ecoGetTag
    , ecoArrayGet, ecoArraySet, ecoArrayLength
    , arithConstantInt, arithConstantInt32, arithConstantFloat, arithConstantBool, arithConstantChar, arithCmpI
    , scfWhile, scfCondition
    , ecoCaseMany, ecoCaseStringMany, ecoYieldMany, scfYieldMany
    , ecoPapCreateGroup, GroupSibling
    , aggCustomType, aggTupleType, ecoCallNamedMulti, ecoFromHeap, ecoGlobal, ecoMakeCustom, ecoMakeTuple2, ecoMakeTuple3, ecoProjectCustomAgg, ecoProjectTuple2Agg, ecoProjectTuple3Agg, ecoReturnMulti, ecoToHeap, funcFuncMulti
    )

{-| MLIR operation builders.

This module provides helper functions for building MLIR operations
in the eco dialect and standard dialects (arith, scf, func).


# Op Builder Plumbing

@docs opBuilder, mlirOp, mkRegion, mkRegionTerminatedByOps, funcFunc


# Eco Constants

@docs ecoConstantUnit, ecoConstantEmptyRec, ecoConstantTrue, ecoConstantFalse, ecoConstantNil, ecoConstantNothing, ecoConstantEmptyString


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

@docs ecoPapCreateGroup, GroupSibling

-}

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


{-| Operation builder functions for MLIR.
-}
opBuilder : Mlir.OpBuilderFns e
opBuilder =
    Mlir.opBuilder


{-| Create an MLIR operation with the given opcode.
-}
mlirOp : Ctx.Context -> String -> Mlir.OpBuilder Ctx.Context
mlirOp env =
    Mlir.mlirOp (\e -> Ctx.freshOpId e |> (\( id, ctx ) -> ( ctx, id ))) env



-- ====== ECO CONSTANTS ======


{-| eco.constant - create an embedded constant value.

The `kind` is a 2-bit constant code matching the runtime `Constant` enum and
`value_enc::ConstantKind` (see plan D3/D6):

  - False = 0
  - True = 1
  - Empty = 2 (the unified empty constant: Unit, EmptyRec, Nil, Nothing, "")

The five former empty constants now all emit kind 2; the type checker guarantees
each is only produced/matched where its type is expected, so a shared bit pattern
is safe.

-}
ecoConstantUnit : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantUnit ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Create an eco.constant op for an empty record.
-}
ecoConstantEmptyRec : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmptyRec ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Create an eco.constant op for True (kind 1).
-}
ecoConstantTrue : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantTrue ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 1))
        |> opBuilder.build


{-| Create an eco.constant op for False (kind 0).
-}
ecoConstantFalse : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantFalse ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 0))
        |> opBuilder.build


{-| Create an eco.constant op for Nil (empty list) — the unified empty constant.
-}
ecoConstantNil : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantNil ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Create an eco.constant op for Nothing — the unified empty constant.
-}
ecoConstantNothing : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantNothing ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Create an eco.constant op for an empty string — the unified empty constant.
-}
ecoConstantEmptyString : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmptyString ctx resultVar =
    ecoConstantEmpty ctx resultVar


{-| Create an eco.constant op for the unified empty constant (kind 2), shared by
Unit, EmptyRec, Nil, Nothing, and the empty string.
-}
ecoConstantEmpty : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmpty ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 2))
        |> opBuilder.build



-- ====== ECO CONSTRUCTION ======


{-| eco.construct.list - create a list cons cell
-}
ecoConstructList : Ctx.Context -> List ( String, MlirType ) -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Bool -> ( Ctx.Context, MlirOp )
ecoConstructList ctx gcRootHints resultVar ( headVar, headType ) ( tailVar, tailType ) headUnboxed =
    let
        -- `head_kind` encodes the 2-bit slot kind (0=boxed, 1=Int, 2=Float, 3=Char)
        -- derived from the head operand type. Lowering reads this to populate
        -- `cons->header.unboxed` slot 0.
        headKind =
            if headUnboxed then
                Types.mlirTypeToKind headType

            else
                0

        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        attrs =
            Dict.fromList
                [ ( "_operand_types"
                  , ArrayAttr Nothing
                        (TypeAttr headType :: TypeAttr tailType :: List.map TypeAttr rootTypes)
                  )
                , ( "head_unboxed", BoolAttr headUnboxed )
                , ( "head_kind", IntAttr Nothing headKind )
                ]
    in
    mlirOp ctx "eco.construct.list"
        |> opBuilder.withOperands (headVar :: tailVar :: rootNames)
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.tuple2 - create a 2-tuple
-}
ecoConstructTuple2 : Ctx.Context -> List ( String, MlirType ) -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Ctx.Context, MlirOp )
ecoConstructTuple2 ctx gcRootHints resultVar ( aVar, aType ) ( bVar, bType ) unboxedBitmap =
    let
        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        attrs =
            Dict.fromList
                [ ( "_operand_types"
                  , ArrayAttr Nothing
                        (TypeAttr aType :: TypeAttr bType :: List.map TypeAttr rootTypes)
                  )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple2"
        |> opBuilder.withOperands (aVar :: bVar :: rootNames)
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.tuple3 - create a 3-tuple
-}
ecoConstructTuple3 : Ctx.Context -> List ( String, MlirType ) -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Ctx.Context, MlirOp )
ecoConstructTuple3 ctx gcRootHints resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) unboxedBitmap =
    let
        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        attrs =
            Dict.fromList
                [ ( "_operand_types"
                  , ArrayAttr Nothing
                        (TypeAttr aType :: TypeAttr bType :: TypeAttr cType :: List.map TypeAttr rootTypes)
                  )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple3"
        |> opBuilder.withOperands (aVar :: bVar :: cVar :: rootNames)
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.record - create a record
-}
ecoConstructRecord : Ctx.Context -> List ( String, MlirType ) -> String -> List ( String, MlirType ) -> Int -> Int -> ( Ctx.Context, MlirOp )
ecoConstructRecord ctx gcRootHints resultVar fieldPairs fieldCount unboxedBitmap =
    let
        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        allOperands =
            List.map Tuple.first fieldPairs ++ rootNames

        allTypes =
            List.map Tuple.second fieldPairs ++ rootTypes

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
                    , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                    ]
                )
    in
    mlirOp ctx "eco.construct.record"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.custom - create a custom ADT value
-}
ecoConstructCustom : Ctx.Context -> List ( String, MlirType ) -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> Maybe String -> ( Ctx.Context, MlirOp )
ecoConstructCustom ctx gcRootHints resultVar tag size unboxedBitmap operands maybeCtorName =
    let
        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        allOperands =
            List.map Tuple.first operands ++ rootNames

        allTypes =
            List.map Tuple.second operands ++ rootTypes

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
                        , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                        ]
                    )
                )
    in
    mlirOp ctx "eco.construct.custom"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build



-- ====== ECO PROJECTION ======


{-| eco.project.list\_head - extract head from a cons cell
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


{-| eco.project.list\_tail - extract tail from a cons cell
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


{-| eco.project.tuple2 - extract field from a 2-tuple
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


{-| eco.project.tuple3 - extract field from a 3-tuple
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



-- ====== VALUE-AGGREGATE OPS (U-T1.3.1, plans/opt-tier1-aggregate-promotion.md) ======


{-| Render an SSA slot type for an aggregate type-parameter list.
Slot types are only ever i64/f64/i16 (unboxed primitives) or a named eco
type (boxed `!eco.value`) — the promoted form mirrors the heap layout's
slot discipline exactly (CGEN\_061: no heap-layout attrs on value ops).
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
            -- Function types never appear as tuple slot SSA types (closures
            -- are !eco.value); render defensively as the boxed form.
            "!eco.value"


{-| The parameterised value-tuple type, e.g. `!eco.tuple2<i64, !eco.value>`
(as a `NamedStruct` so text and bytecode both render it verbatim — the
bytecode path encodes NamedStruct as a dialect asm type).
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


{-| eco.make.tuple2 — build a VALUE-level 2-tuple (`!eco.tuple2<...>`), no
heap allocation (Pure, CGEN\_061; lowered to insertvalue chains by
EcoToLLVMValueAgg and dissolved by SROA before RS4GC — REP\_AGG\_001).
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


{-| eco.make.tuple3 — build a VALUE-level 3-tuple (`!eco.tuple3<...>`).
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


{-| The parameterised value-custom type, e.g.
`!eco.custom<i64, !eco.value>` (slot types per the ctor layout — tag is
structural, on the op, never in the type: Q-B/CGEN\_061).
-}
aggCustomType : List MlirType -> MlirType
aggCustomType slotTypes =
    NamedStruct ("eco.custom<" ++ String.join ", " (List.map aggSlotTypeString slotTypes) ++ ">")


{-| eco.make.custom — build a VALUE-level custom (U-T1.3.2): no heap
allocation; `tag` + `constructor` attrs mirror `eco.construct.custom`
minus the heap-layout bitmap (value slots carry their types in the
parameterised result type instead).
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


{-| eco.project.custom over a VALUE-level custom operand (see
`ecoProjectTuple2Agg` for why `_operand_types` must carry the aggregate).
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


{-| eco.project.tuple2 over a VALUE-level tuple operand: identical to
`ecoProjectTuple2` but `_operand_types` carries the aggregate type (the
dual-form lowering dispatches on the converted operand type; the attr must
not lie about it or the parse re-types the operand as `!eco.value`).
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


{-| eco.project.tuple3 over a VALUE-level tuple operand (see
`ecoProjectTuple2Agg`).
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


{-| eco.project.record - extract field from a record
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


{-| eco.project.custom - extract field from a custom ADT
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


{-| kernel-opt-12: is this callee symbol safe to merge AND to erase?
Whitelist discipline — anything the table does not list (every non-kernel
symbol included) answers False and the emitter stamps nothing, which is
exactly today's behaviour. `lookupSymbol` owns prefix + ABI-suffix
normalisation (kernel-opt-07 cross-plan contract pt 3).
-}
calleeIsDroppable : String -> Bool
calleeIsDroppable funcName =
    KernelFacts.lookupSymbol funcName
        |> Maybe.map KernelFacts.droppable
        |> Maybe.withDefault False


{-| eco.call - call a function by name
-}
ecoCallNamed : Ctx.Context -> List ( String, MlirType ) -> String -> String -> List ( String, MlirType ) -> MlirType -> ( Ctx.Context, MlirOp )
ecoCallNamed ctx gcRootHints resultVar funcName operands returnType =
    let
        -- Register kernel functions for declaration generation. ABI args are the
        -- non-hint operands only; GC root hints are appended at the tail and are
        -- not part of the callee signature.
        ctxWithKernel =
            if String.startsWith "Elm_Kernel_" funcName || String.startsWith "Eco_Kernel_" funcName then
                Ctx.registerKernelCall ctx funcName (List.map Tuple.second operands) returnType

            else
                ctx

        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        allOperands =
            List.map Tuple.first operands ++ rootNames

        allTypes =
            List.map Tuple.second operands ++ rootTypes

        operandTypesAttr =
            if List.isEmpty allOperands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr allTypes))

        -- `eco.gc_roots_count` tells the C++ GCRootCarrier interface how many
        -- tail operands are appended roots (vs. real call args). Omit when zero
        -- to keep call ops textually unchanged when there are no hints.
        gcRootsCountAttr =
            if List.isEmpty gcRootHints then
                Dict.empty

            else
                Dict.singleton "eco.gc_roots_count" (IntAttr Nothing (List.length gcRootHints))

        -- kernel-opt-12: purity channel. Stamped ONLY for direct calls whose
        -- KernelFacts row derives `droppable`. Unlisted callee => no attr =>
        -- CallOp::getEffects reports conservative read+write (today's
        -- behaviour). Never stamped when the flag is off.
        csePurityAttr =
            if ctx.ecoConfig.callPurityAttrs && calleeIsDroppable funcName then
                Dict.singleton "eco.cse_safe" UnitAttr

            else
                Dict.empty

        attrs =
            Dict.union csePurityAttr
                (Dict.union operandTypesAttr
                    (Dict.union gcRootsCountAttr
                        (Dict.singleton "callee" (SymbolRefAttr funcName))
                    )
                )
    in
    mlirOp ctxWithKernel "eco.call"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults [ ( resultVar, returnType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.return - return a value from a function or joinpoint body
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


{-| U-T1.3.3: multi-operand eco.return — the terminator of an sret worker.
The lowering (EcoToLLVMControlFlow's multi arm) stores each operand into
the caller's slot immediately before returning void (CGEN\_067).
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


{-| U-T1.3.3: multi-result direct call to an sret worker. The lowering
(EcoToLLVMClosures' multi arm) allocates the slot in the caller's entry
block, passes it as the leading argument, and reloads the fields.
-}
ecoCallNamedMulti : Ctx.Context -> List ( String, MlirType ) -> List ( String, MlirType ) -> String -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoCallNamedMulti ctx gcRootHints resultPairs funcName operands =
    let
        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        allOperands =
            List.map Tuple.first operands ++ rootNames

        allTypes =
            List.map Tuple.second operands ++ rootTypes

        operandTypesAttr =
            if List.isEmpty allOperands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr allTypes))

        gcRootsCountAttr =
            if List.isEmpty gcRootHints then
                Dict.empty

            else
                Dict.singleton "eco.gc_roots_count" (IntAttr Nothing (List.length gcRootHints))

        -- kernel-opt-12: same purity channel as ecoCallNamed — the $sret
        -- worker path can also target a kernel.
        csePurityAttr =
            if ctx.ecoConfig.callPurityAttrs && calleeIsDroppable funcName then
                Dict.singleton "eco.cse_safe" UnitAttr

            else
                Dict.empty

        attrs =
            Dict.union csePurityAttr
                (Dict.union operandTypesAttr
                    (Dict.union gcRootsCountAttr
                        (Dict.singleton "callee" (SymbolRefAttr funcName))
                    )
                )
    in
    mlirOp ctx "eco.call"
        |> opBuilder.withOperands allOperands
        |> opBuilder.withResults resultPairs
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.to\_heap — box an SSA value aggregate into a heap object (the
allocating mirror of from\_heap; GCRootCarrier).
-}
ecoToHeap : Ctx.Context -> List ( String, MlirType ) -> String -> ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoToHeap ctx gcRootHints resultVar ( aggVar, aggType ) =
    let
        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        attrs =
            Dict.union
                (Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr (aggType :: rootTypes)))
                )
                (if List.isEmpty gcRootHints then
                    Dict.empty

                 else
                    Dict.singleton "eco.gc_roots_count" (IntAttr Nothing (List.length gcRootHints))
                )
    in
    mlirOp ctx "eco.to_heap"
        |> opBuilder.withOperands (aggVar :: rootNames)
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| U-T1.3.3: eco.from\_heap — unbox a heap aggregate (addressed by
`!eco.value`) into the corresponding SSA value aggregate. Pure loads;
used to bridge a boxed value onto the aggregate result spine.
-}
ecoFromHeap : Ctx.Context -> String -> MlirType -> String -> ( Ctx.Context, MlirOp )
ecoFromHeap ctx resultVar aggType operandVar =
    mlirOp ctx "eco.from_heap"
        |> opBuilder.withOperands [ operandVar ]
        |> opBuilder.withResults [ ( resultVar, aggType ) ]
        |> opBuilder.withAttrs (Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ]))
        |> opBuilder.build


{-| eco.yield - yield a value from an eco.case alternative region
-}
ecoYield : Ctx.Context -> String -> MlirType -> ( Ctx.Context, MlirOp )
ecoYield ctx operand operandType =
    ecoYieldMany ctx [ ( operand, operandType ) ]


{-| eco.yield with multiple operands - yield values from an eco.case alternative region.
The \_operand\_types attribute must exactly match the operand count (including empty list for 0 operands).
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


{-| eco.string\_literal - create a string constant
-}
ecoStringLiteral : Ctx.Context -> String -> String -> ( Ctx.Context, MlirOp )
ecoStringLiteral ctx resultVar value =
    mlirOp ctx "eco.string_literal"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (StringAttr value))
        |> opBuilder.build



-- ====== ARITH DIALECT ======


{-| arith.constant for integers
-}
arithConstantInt : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
arithConstantInt ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I64 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I64) value))
        |> opBuilder.build


{-| arith.constant for i32 integers (used for tags)
-}
arithConstantInt32 : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
arithConstantInt32 ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I32 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) value))
        |> opBuilder.build


{-| arith.cmpi for integer comparison (returns i1)
Predicate values: eq=0, ne=1, slt=2, sle=3, sgt=4, sge=5, ult=6, ule=7, ugt=8, uge=9
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


{-| arith.constant for floats
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


{-| arith.constant for booleans
-}
arithConstantBool : Ctx.Context -> String -> Bool -> ( Ctx.Context, MlirOp )
arithConstantBool ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I1 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (BoolAttr value))
        |> opBuilder.build


{-| arith.constant for characters
-}
arithConstantChar : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
arithConstantChar ctx resultVar codepoint =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoChar ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just Types.ecoChar) codepoint))
        |> opBuilder.build



-- ====== ECO OPERATORS ======


{-| Build a unary eco op (e.g., eco.int.negate, eco.float.sqrt)
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


{-| Build a binary eco op (e.g., eco.int.add, eco.float.mul)
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


{-| Build a nullary eco op (no operands), e.g., eco.array.empty.
-}
ecoNullaryOp : Ctx.Context -> String -> String -> MlirType -> ( Ctx.Context, MlirOp )
ecoNullaryOp ctx opName resultVar resultTy =
    mlirOp ctx opName
        |> opBuilder.withResults [ ( resultVar, resultTy ) ]
        |> opBuilder.build


{-| Build a ternary eco op (e.g., eco.array.slice). Each operand carries
its MLIR type so the standard `_operand_types` attribute is set correctly
for downstream type-aware passes.
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


{-| Generate an eco.array.get operation.
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


{-| Generate an eco.array.set operation.
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


{-| Generate an eco.array.length operation.
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


{-| Create a region with a single entry block
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


{-| Build a region from ops that already end with a terminator.
The last op becomes the region's terminator.
Use this when the body ends with eco.case or eco.jump.
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


{-| eco.global - module-level GC-rooted value slot (CAF memoization,
plans/caf-memoization-implementation.md). Lowered to an internal i64 LLVM
global initialized to 0 and registered as a GC root at startup by
`__eco_init_globals` (EcoToLLVMGlobals.cpp). No operands, results, or
regions — an attr-only module-level op like eco.type\_table.
-}
ecoGlobal : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoGlobal ctx symName =
    mlirOp ctx "eco.global"
        |> opBuilder.withAttrs (Dict.fromList [ ( "sym_name", StringAttr symName ) ])
        |> opBuilder.build


{-| func.func - define a function
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


{-| U-T1.3.3: a MULTI-RESULT func.func — the sret worker form. The C++
side (SretFuncOpLowering) recognises any func.func with 2+ results and
lowers it to the (slot ptr, args...) -> void ABI.
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


{-| eco.case - pattern matching expression that produces SSA results

Takes a result variable name, scrutinee SSA name, scrutinee type, case kind ("ctor", "int", "chr", "str"),
list of tags, list of regions (one per alternative), and result type.
Emits an eco.case operation that produces an SSA result value.

eco.case is NOT a terminator - it's a value-producing expression.
Each alternative region must terminate with eco.yield.

-}
ecoCase : Ctx.Context -> String -> String -> MlirType -> String -> List Int -> List MlirRegion -> MlirType -> ( Ctx.Context, MlirOp )
ecoCase ctx resultVar scrutinee scrutineeType caseKind tags regions resultType =
    ecoCaseMany ctx scrutinee scrutineeType caseKind tags regions [ ( resultVar, resultType ) ]


{-| eco.case for string pattern matching.

Takes a result variable name, scrutinee SSA name, scrutinee type, list of tags (positional indices),
list of string patterns (N-1 for N alternatives, last is default),
list of regions (one per alternative), and result type.
Emits an eco.case operation with string\_patterns attribute.

eco.case is NOT a terminator - it's a value-producing expression.
Each alternative region must terminate with eco.yield.

-}
ecoCaseString : Ctx.Context -> String -> String -> MlirType -> List Int -> List String -> List MlirRegion -> MlirType -> ( Ctx.Context, MlirOp )
ecoCaseString ctx resultVar scrutinee scrutineeType tags stringPatterns regions resultType =
    ecoCaseStringMany ctx scrutinee scrutineeType tags stringPatterns regions [ ( resultVar, resultType ) ]


{-| eco.case with multiple results - for TailRec step compilation.

Takes scrutinee SSA name, scrutinee type, case kind, list of tags,
list of regions (one per alternative), and list of result (name, type) pairs.
Emits an eco.case operation that produces multiple SSA values.

eco.case is NOT a terminator - it's a value-producing expression.
Each alternative region must terminate with eco.yieldMany yielding values
matching the result types in order.

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


{-| eco.case for string pattern matching with multiple results.

Takes scrutinee SSA name, scrutinee type, list of tags (positional indices),
list of string patterns (N-1 for N alternatives, last is default),
list of regions (one per alternative), and list of result (name, type) pairs.
Emits an eco.case operation with string\_patterns attribute.

eco.case is NOT a terminator - it's a value-producing expression.
Each alternative region must terminate with eco.yieldMany yielding values
matching the result types in order.

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


{-| eco.getTag - get the tag from a value (for eco.case scrutinee)
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


{-| scf.yield with multiple operands - terminator for scf.if/scf.while regions.
The \_operand\_types attribute must exactly match the operand count (including empty list for 0 operands).
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


{-| scf.while - structured while loop.

Structure:
%results = scf.while (%args = %inits) : (ArgTypes) -> ResultTypes {
// "before" region - condition computation
scf.condition(%cond) %args : ArgTypes
} do {
^bb0(%args: ArgTypes):
// "after" region - body computation
scf.yield %newArgs : ArgTypes
}

The before region computes the condition and passes values to either exit or continue.
The after region computes new values for the next iteration.

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


{-| scf.condition - terminator for scf.while "before" region.

If condition is true, continues to "after" region with the provided values.
If condition is false, exits the while loop, returning the provided values as results.

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



-- ====== ECO papCreateGroup ======


{-| Describes one sibling in a `eco.papCreateGroup` op.

`resultKind` is the saturated return ABI kind (REP\_ABI\_001):

  - 0 = Boxed (HPtr) — default; emitted when the lambda's body evaluates
    to a non-primitive type, including multi-stage closures whose body
    returns another closure.
  - 1 = Int (i64), 2 = Float (f64), 3 = Char (i16) — primitive returns.

The runtime stores this on each sibling's closure header so dispatch
paths cast `closure->evaluator` correctly.

-}
type alias GroupSibling =
    { functionName : String
    , fastEvaluator : String
    , arity : Int
    , numCaptured : Int
    , unboxedBitmap : Int
    , resultKind : Int
    , captureVars : List String
    , captureTypes : List MlirType
    }


{-| Emit a single `eco.papCreateGroup` op that atomically allocates
a group of sibling closures for mutual let-rec. See the runtime op
description for details on the attribute layout.

`siblings` are listed in sibling-index order. `crossEdges` is a list of
`(producer, consumer, slot)` triples where slot indexes into the
consumer's `values[]` array. `resultVars` are the SSA names to bind
the resulting closure HPointers to, in sibling order.

-}
ecoPapCreateGroup :
    Ctx.Context
    -> List ( String, MlirType )
    -> List GroupSibling
    -> List ( Int, Int, Int )
    -> List String
    -> ( Ctx.Context, MlirOp )
ecoPapCreateGroup ctx gcRootHints siblings crossEdges resultVars =
    let
        functions =
            siblings |> List.map (.functionName >> SymbolRefAttr) |> ArrayAttr Nothing

        fastEvaluators =
            siblings |> List.map (.fastEvaluator >> SymbolRefAttr) |> ArrayAttr Nothing

        -- Emit as a standard ArrayAttr<IntegerAttr<i64>> (printed as
        -- `[1 : i64, 2 : i64, ...]`) — matches TableGen `I64ArrayAttr`.
        -- `ArrayAttr (Just I64) ...` would serialize as the distinct
        -- `DenseI64ArrayAttr` form (`array<i64: ...>`), which the op
        -- verifier does not accept.
        i64Array ints =
            ArrayAttr Nothing (List.map (\i -> IntAttr (Just I64) i) ints)

        arities =
            siblings |> List.map .arity |> i64Array

        numCaptured =
            siblings |> List.map .numCaptured |> i64Array

        unboxedBitmaps =
            siblings |> List.map .unboxedBitmap |> i64Array

        -- Per-sibling result kinds (REP_ABI_001). The op spec declares
        -- `_result_kinds` as `OptionalAttr<I64ArrayAttr>`, so emit values
        -- through `i64Array` (TableGen's verifier rejects I8-typed entries).
        -- The runtime stores the byte on each sibling's closure header, so
        -- only the low 8 bits matter — but we send full i64 to satisfy the
        -- verifier. Omitted when every sibling is PK_Boxed to keep MLIR
        -- diffs minimal.
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

        ( rootNames, rootTypes ) =
            List.unzip gcRootHints

        operandVars =
            captureVars ++ rootNames

        operandTypes =
            captureTypes ++ rootTypes

        operandTypesAttr =
            if List.isEmpty operandTypes then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr operandTypes))

        -- Append-pattern GCRootCarrier (Pattern 3): eco.gc_roots_count tells
        -- the C++ side how many trailing operands are roots vs captures.
        gcRootsCountAttr =
            if List.isEmpty gcRootHints then
                Dict.empty

            else
                Dict.singleton "eco.gc_roots_count" (IntAttr Nothing (List.length gcRootHints))

        attrs =
            Dict.union resultKindsAttrs
                (Dict.union operandTypesAttr
                    (Dict.union gcRootsCountAttr
                        (Dict.fromList
                            [ ( "functions", functions )
                            , ( "fast_evaluators", fastEvaluators )
                            , ( "arities", arities )
                            , ( "num_captured", numCaptured )
                            , ( "unboxed_bitmaps", unboxedBitmaps )
                            , ( "capture_counts", captureCounts )
                            , ( "cross_edges", flatCrossEdges )
                            ]
                        )
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
