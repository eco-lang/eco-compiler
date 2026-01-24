module Compiler.Generate.MLIR.Ops exposing
    ( opBuilder
    , mlirOp
    , mkRegion
    , mkRegionTerminatedByOps
    , funcFunc
    , ecoConstantUnit
    , ecoConstantEmptyRec
    , ecoConstantTrue
    , ecoConstantFalse
    , ecoConstantNil
    , ecoConstantNothing
    , ecoConstantEmptyString
    , ecoConstructList
    , ecoConstructTuple2
    , ecoConstructTuple3
    , ecoConstructRecord
    , ecoConstructCustom
    , ecoProjectListHead
    , ecoProjectListTail
    , ecoProjectTuple2
    , ecoProjectTuple3
    , ecoProjectRecord
    , ecoProjectCustom
    , ecoCallNamed
    , ecoReturn
    , ecoStringLiteral
    , arithConstantInt
    , arithConstantInt32
    , arithConstantFloat
    , arithConstantBool
    , arithConstantChar
    , arithCmpI
    , ecoUnaryOp
    , ecoBinaryOp
    , ecoCase
    , ecoCaseString
    , ecoJoinpoint
    , ecoGetTag
    , scfIf
    , scfYield
    , scfWhile
    , scfCondition
    , cfCondBr
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

@docs ecoCallNamed, ecoReturn, ecoStringLiteral, ecoUnaryOp, ecoBinaryOp, ecoCase, ecoCaseString, ecoJoinpoint, ecoGetTag


# Arith Operations

@docs arithConstantInt, arithConstantInt32, arithConstantFloat, arithConstantBool, arithConstantChar, arithCmpI


# SCF Operations

@docs scfIf, scfYield

-}

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
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

Constants from Ops.td (1-indexed for MLIR):

  - Unit = 1
  - EmptyRec = 2
  - True = 3
  - False = 4
  - Nil = 5
  - Nothing = 6
  - EmptyString = 7

-}
ecoConstantUnit : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantUnit ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 1))
        |> opBuilder.build


{-| Create an eco.constant op for an empty record.
-}
ecoConstantEmptyRec : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmptyRec ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 2))
        |> opBuilder.build


{-| Create an eco.constant op for True.
-}
ecoConstantTrue : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantTrue ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 3))
        |> opBuilder.build


{-| Create an eco.constant op for False.
-}
ecoConstantFalse : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantFalse ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 4))
        |> opBuilder.build


{-| Create an eco.constant op for Nil (empty list).
-}
ecoConstantNil : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantNil ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 5))
        |> opBuilder.build


{-| Create an eco.constant op for Nothing.
-}
ecoConstantNothing : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantNothing ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 6))
        |> opBuilder.build


{-| Create an eco.constant op for an empty string.
-}
ecoConstantEmptyString : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoConstantEmptyString ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 7))
        |> opBuilder.build



-- ====== ECO CONSTRUCTION ======


{-| eco.construct.list - create a list cons cell
-}
ecoConstructList : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Bool -> ( Ctx.Context, MlirOp )
ecoConstructList ctx resultVar ( headVar, headType ) ( tailVar, tailType ) headUnboxed =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr headType, TypeAttr tailType ] )
                , ( "head_unboxed", BoolAttr headUnboxed )
                ]
    in
    mlirOp ctx "eco.construct.list"
        |> opBuilder.withOperands [ headVar, tailVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.tuple2 - create a 2-tuple
-}
ecoConstructTuple2 : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Ctx.Context, MlirOp )
ecoConstructTuple2 ctx resultVar ( aVar, aType ) ( bVar, bType ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr aType, TypeAttr bType ] )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple2"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.tuple3 - create a 3-tuple
-}
ecoConstructTuple3 : Ctx.Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Ctx.Context, MlirOp )
ecoConstructTuple3 ctx resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr aType, TypeAttr bType, TypeAttr cType ] )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple3"
        |> opBuilder.withOperands [ aVar, bVar, cVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.record - create a record
-}
ecoConstructRecord : Ctx.Context -> String -> List ( String, MlirType ) -> Int -> Int -> ( Ctx.Context, MlirOp )
ecoConstructRecord ctx resultVar fieldPairs fieldCount unboxedBitmap =
    let
        operandNames =
            List.map Tuple.first fieldPairs

        operandTypesAttr =
            if List.isEmpty fieldPairs then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) fieldPairs))

        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    [ ( "field_count", IntAttr Nothing fieldCount )
                    , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                    ]
                )
    in
    mlirOp ctx "eco.construct.record"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.custom - create a custom ADT value
-}
ecoConstructCustom : Ctx.Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> Maybe String -> ( Ctx.Context, MlirOp )
ecoConstructCustom ctx resultVar tag size unboxedBitmap operands maybeCtorName =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

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
        |> opBuilder.withOperands operandNames
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


{-| eco.call - call a function by name
-}
ecoCallNamed : Ctx.Context -> String -> String -> List ( String, MlirType ) -> MlirType -> ( Ctx.Context, MlirOp )
ecoCallNamed ctx resultVar funcName operands returnType =
    let
        -- Register kernel functions for declaration generation
        ctxWithKernel =
            if String.startsWith "Elm_Kernel_" funcName then
                Ctx.registerKernelCall ctx funcName (List.map Tuple.second operands) returnType

            else
                ctx

        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

        attrs =
            Dict.union operandTypesAttr
                (Dict.singleton "callee" (SymbolRefAttr funcName))
    in
    mlirOp ctxWithKernel "eco.call"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, returnType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.return - return a value
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



-- ====== CONTROL FLOW ======


{-| eco.case - pattern matching control flow

Takes a scrutinee SSA name, scrutinee type, case kind ("ctor", "int", "chr", "str"),
list of tags, list of regions (one per alternative), and result types.
Emits an eco.case operation.

-}
ecoCase : Ctx.Context -> String -> MlirType -> String -> List Int -> List MlirRegion -> List MlirType -> ( Ctx.Context, MlirOp )
ecoCase ctx scrutinee scrutineeType caseKind tags regions resultTypes =
    let
        attrsBase =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr scrutineeType ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                , ( "case_kind", StringAttr caseKind )
                ]

        attrs =
            Dict.insert "caseResultTypes"
                (ArrayAttr Nothing (List.map TypeAttr resultTypes))
                attrsBase
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| eco.case for string pattern matching.

Takes a scrutinee SSA name, scrutinee type, list of tags (positional indices),
list of string patterns (N-1 for N alternatives, last is default),
list of regions (one per alternative), and result types.
Emits an eco.case operation with string_patterns attribute.

-}
ecoCaseString : Ctx.Context -> String -> MlirType -> List Int -> List String -> List MlirRegion -> List MlirType -> ( Ctx.Context, MlirOp )
ecoCaseString ctx scrutinee scrutineeType tags stringPatterns regions resultTypes =
    let
        attrsBase =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr scrutineeType ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                , ( "case_kind", StringAttr "str" )
                , ( "string_patterns", ArrayAttr Nothing (List.map StringAttr stringPatterns) )
                ]

        attrs =
            Dict.insert "caseResultTypes"
                (ArrayAttr Nothing (List.map TypeAttr resultTypes))
                attrsBase
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| eco.joinpoint - local control-flow join with a body and continuation

Takes a joinpoint id, parameter types, the body region, continuation region,
and result types.

-}
ecoJoinpoint : Ctx.Context -> Int -> List ( String, MlirType ) -> MlirRegion -> MlirRegion -> List MlirType -> ( Ctx.Context, MlirOp )
ecoJoinpoint ctx id params jpRegion contRegion resultTypes =
    let
        attrsBase =
            Dict.fromList [ ( "id", IntAttr Nothing id ) ]

        attrs =
            if List.isEmpty resultTypes then
                attrsBase

            else
                Dict.insert "jpResultTypes"
                    (ArrayAttr Nothing (List.map TypeAttr resultTypes))
                    attrsBase

        -- Build the jp region with params
        jpRegionWithParams =
            case jpRegion of
                MlirRegion r ->
                    MlirRegion { r | entry = { args = params, body = r.entry.body, terminator = r.entry.terminator } }
    in
    mlirOp ctx "eco.joinpoint"
        |> opBuilder.withRegions [ jpRegionWithParams, contRegion ]
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


{-| scf.if - direct structured control flow for i1 boolean conditions.
Use this for Bool pattern matching instead of eco.case, since eco.case
uses eco.get\_tag which dereferences the value as a pointer.
-}
scfIf : Ctx.Context -> String -> String -> MlirRegion -> MlirRegion -> MlirType -> ( Ctx.Context, MlirOp )
scfIf ctx condVar resultVar thenRegion elseRegion resultType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr I1 ])
    in
    mlirOp ctx "scf.if"
        |> opBuilder.withOperands [ condVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withRegions [ thenRegion, elseRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| scf.yield - terminator for scf.if regions.
-}
scfYield : Ctx.Context -> String -> MlirType -> ( Ctx.Context, MlirOp )
scfYield ctx operand operandType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr operandType ])
    in
    mlirOp ctx "scf.yield"
        |> opBuilder.withOperands [ operand ]
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


{-| cf.cond\_br - conditional branch to two different blocks.
Used inside joinpoints for tail-recursive loops where one path returns
and another path jumps back.

cf.cond\_br %cond, ^trueBlock, ^falseBlock

-}
cfCondBr : Ctx.Context -> String -> String -> String -> ( Ctx.Context, MlirOp )
cfCondBr ctx condVar trueBlock falseBlock =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr I1 ] )
                , ( "operandSegmentSizes", ArrayAttr (Just I32) [ IntAttr Nothing 1, IntAttr Nothing 0, IntAttr Nothing 0 ] )
                ]
    in
    mlirOp ctx "cf.cond_br"
        |> opBuilder.withOperands [ condVar ]
        |> opBuilder.withSuccessors [ "^" ++ trueBlock, "^" ++ falseBlock ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build
