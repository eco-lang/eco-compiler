module Compiler.Generate.MLIR.Lambdas exposing
    ( processLambdas
    , processPendingWrappers
    )

{-| Lambda and PAP wrapper processing for the MLIR backend.

This module handles:

  - Processing pending lambdas into func.func ops
  - Generating PAP wrapper functions for unboxed params

@docs processLambdas, processPendingWrappers

-}

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..))


-- ====== LAMBDA PROCESSING ======


{-| Process pending lambdas and generate their function definitions.
-}
processLambdas : Ctx.Context -> ( List MlirOp, Ctx.Context )
processLambdas ctx =
    case ctx.pendingLambdas of
        [] ->
            ( [], ctx )

        lambdas ->
            let
                ctxCleared =
                    { ctx | pendingLambdas = [] }

                ( lambdaOps, ctxAfter ) =
                    List.foldl
                        (\lambda ( accOps, accCtx ) ->
                            let
                                ( op, newCtx ) =
                                    generateLambdaFunc accCtx lambda
                            in
                            ( accOps ++ [ op ], newCtx )
                        )
                        ( [], ctxCleared )
                        lambdas

                ( moreOps, finalCtx ) =
                    processLambdas ctxAfter
            in
            ( lambdaOps ++ moreOps, finalCtx )


generateLambdaFunc : Ctx.Context -> Ctx.PendingLambda -> ( MlirOp, Ctx.Context )
generateLambdaFunc ctx lambda =
    let
        -- All parameters use !eco.value in the signature (boxed calling convention)
        captureArgPairs : List ( String, MlirType )
        captureArgPairs =
            List.map (\( name, _ ) -> ( "%" ++ name, Types.ecoValue )) lambda.captures

        -- Use !eco.value for all params in signature - callers pass boxed values
        paramArgPairs : List ( String, MlirType )
        paramArgPairs =
            List.map (\( name, _ ) -> ( "%" ++ name, Types.ecoValue )) lambda.params

        allArgPairs : List ( String, MlirType )
        allArgPairs =
            captureArgPairs ++ paramArgPairs

        -- Generate unbox operations for parameters that need primitive types
        -- and build the varMappings with the unboxed variable names
        ( unboxOps, varMappingsWithParams, ctxAfterUnbox ) =
            List.foldl
                (\( name, ty ) ( opsAcc, mappingsAcc, ctxAcc ) ->
                    let
                        paramMlirType =
                            Types.monoTypeToMlir ty

                        boxedVarName =
                            "%" ++ name
                    in
                    if Types.isEcoValueType paramMlirType then
                        -- Parameter is already !eco.value, no unboxing needed
                        ( opsAcc
                        , Dict.insert name ( boxedVarName, Types.ecoValue ) mappingsAcc
                        , ctxAcc
                        )

                    else
                        -- Need to unbox the parameter
                        let
                            ( unboxedVar, ctxU1 ) =
                                Ctx.freshVar ctxAcc

                            attrs =
                                Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

                            ( ctxU2, unboxOp ) =
                                Ops.mlirOp ctxU1 "eco.unbox"
                                    |> Ops.opBuilder.withOperands [ boxedVarName ]
                                    |> Ops.opBuilder.withResults [ ( unboxedVar, paramMlirType ) ]
                                    |> Ops.opBuilder.withAttrs attrs
                                    |> Ops.opBuilder.build
                        in
                        ( opsAcc ++ [ unboxOp ]
                        , Dict.insert name ( unboxedVar, paramMlirType ) mappingsAcc
                        , ctxU2
                        )
                )
                ( []
                , List.foldl
                    (\( name, _ ) acc -> Dict.insert name ( "%" ++ name, Types.ecoValue ) acc)
                    Dict.empty
                    lambda.captures
                , { ctx | nextVar = List.length allArgPairs }
                )
                lambda.params

        -- Merge sibling mappings with captures and params (captures/params take precedence)
        siblingKeys : List String
        siblingKeys =
            Dict.keys lambda.siblingMappings

        varMappingsWithSiblings : Dict.Dict String ( String, MlirType )
        varMappingsWithSiblings =
            Dict.union varMappingsWithParams lambda.siblingMappings

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctxAfterUnbox | varMappings = varMappingsWithSiblings }

        exprResult : Expr.ExprResult
        exprResult =
            Expr.generateExpr ctxWithArgs lambda.body

        -- Lambda returns use !eco.value (boxed calling convention)
        -- Box the result if needed
        ( boxOps, finalResultVar, ctxAfterBox ) =
            Expr.boxToEcoValue exprResult.ctx exprResult.resultVar exprResult.resultType

        ( ctx1, returnOp ) =
            Ops.ecoReturn ctxAfterBox finalResultVar Types.ecoValue

        region : MlirRegion
        region =
            Ops.mkRegion allArgPairs (unboxOps ++ exprResult.ops ++ boxOps) returnOp

        ( ctx2, funcOp ) =
            Ops.funcFunc ctx1 lambda.name allArgPairs Types.ecoValue region
    in
    ( funcOp, ctx2 )



-- ====== PAP WRAPPER FUNCTION GENERATION ======


{-| Generate all pending PAP wrapper functions accumulated in the context.

Clears ctx.pendingWrappers and returns the generated func.func ops plus the
updated context.

-}
processPendingWrappers : Ctx.Context -> ( List MlirOp, Ctx.Context )
processPendingWrappers ctx =
    case ctx.pendingWrappers of
        [] ->
            ( [], ctx )

        wrappers ->
            let
                ctxCleared : Ctx.Context
                ctxCleared =
                    { ctx | pendingWrappers = [] }

                ( ops, ctxAfter ) =
                    List.foldl
                        (\wrapper ( accOps, accCtx ) ->
                            let
                                ( op, newCtx ) =
                                    generatePapWrapper accCtx wrapper
                            in
                            ( accOps ++ [ op ], newCtx )
                        )
                        ( [], ctxCleared )
                        wrappers
            in
            ( ops, ctxAfter )


{-| Generate a PAP wrapper function.

The wrapper has this ABI:

    wrapperName : (!eco.value, !eco.value, ..., !eco.value) -> !eco.value

It:

  - Accepts all arguments boxed (!eco.value)
  - Unboxes any primitive params according to paramTypes
  - Calls the underlying target function (targetFuncName) with the correct
    primitive / boxed types (Types.monoTypeToMlir paramTypes)
  - Boxes the result back to !eco.value if needed

-}
generatePapWrapper : Ctx.Context -> Ctx.PendingWrapper -> ( MlirOp, Ctx.Context )
generatePapWrapper ctx wrapper =
    let
        paramCount : Int
        paramCount =
            List.length wrapper.paramTypes

        -- Wrapper's external signature: all params boxed as !eco.value
        argNames : List String
        argNames =
            List.indexedMap (\i _ -> "%arg" ++ String.fromInt i) wrapper.paramTypes

        argPairs : List ( String, MlirType )
        argPairs =
            List.map (\name -> ( name, Types.ecoValue )) argNames

        -- Start body with args in scope; next SSA id after args
        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = paramCount }

        -- Unbox parameters that need primitive types
        ( unboxOps, callArgs, ctx1 ) =
            List.foldl
                (\( name, monoParamType ) ( opsAcc, argsAcc, ctxAcc ) ->
                    let
                        paramMlirTy : MlirType
                        paramMlirTy =
                            Types.monoTypeToMlir monoParamType
                    in
                    if Types.isEcoValueType paramMlirTy then
                        -- Parameter is already !eco.value; pass through as-is
                        ( opsAcc
                        , argsAcc ++ [ ( name, Types.ecoValue ) ]
                        , ctxAcc
                        )

                    else
                        -- Need to unbox from !eco.value to the primitive type
                        let
                            ( moreOps, unboxedVar, ctxAcc1 ) =
                                Intrinsics.unboxToType ctxAcc name paramMlirTy
                        in
                        ( opsAcc ++ moreOps
                        , argsAcc ++ [ ( unboxedVar, paramMlirTy ) ]
                        , ctxAcc1
                        )
                )
                ( [], [], ctxWithArgs )
                (List.map2 Tuple.pair argNames wrapper.paramTypes)

        -- Call the underlying target function with unboxed/boxed params
        ( rawResultVar, ctx2 ) =
            Ctx.freshVar ctx1

        targetResultTy : MlirType
        targetResultTy =
            Types.monoTypeToMlir wrapper.returnType

        ( ctx3, callOp ) =
            Ops.ecoCallNamed ctx2 rawResultVar wrapper.targetFuncName callArgs targetResultTy

        -- Wrapper must return !eco.value; box primitive result if needed
        ( boxOps, finalResultVar, ctx4 ) =
            Expr.boxToEcoValue ctx3 rawResultVar targetResultTy

        ( ctx5, returnOp ) =
            Ops.ecoReturn ctx4 finalResultVar Types.ecoValue

        region : MlirRegion
        region =
            Ops.mkRegion argPairs (unboxOps ++ [ callOp ] ++ boxOps) returnOp

        ( ctxFinal, funcOp ) =
            Ops.funcFunc ctx5 wrapper.wrapperName argPairs Types.ecoValue region
    in
    ( funcOp, ctxFinal )
