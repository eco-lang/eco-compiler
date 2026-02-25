module Compiler.Generate.MLIR.Lambdas exposing (processLambdas)

{-| Lambda processing for the MLIR backend.

This module handles processing pending lambdas into func.func ops
with typed ABIs (parameters in their actual types, not all boxed).

@docs processLambdas

-}

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Functions as Functions
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.TailRec as TailRec
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirOp, MlirRegion, MlirType)
import Set



-- ====== LAMBDA PROCESSING ======


{-| Process pending lambdas and generate their function definitions.
-}
processLambdas : Ctx.Context -> ( List MlirOp, Ctx.Context )
processLambdas ctx =
    case ctx.pendingLambdas of
        [] ->
            -- Also drain any pre-generated func ops (e.g. from local tail-rec functions)
            ( ctx.pendingFuncOps, { ctx | pendingFuncOps = [] } )

        lambdas ->
            let
                ctxCleared =
                    { ctx | pendingLambdas = [], pendingFuncOps = [] }

                -- Pre-generated func ops accumulated before this round
                priorFuncOps =
                    ctx.pendingFuncOps

                -- Deduplicate lambdas by name to avoid duplicate function definitions
                -- (can happen when BytesFusion compiles a decoder binding AND the fused path
                -- references the same lambda)
                dedupedLambdas =
                    let
                        ( _, result ) =
                            List.foldl
                                (\lambda ( seen, acc ) ->
                                    if Set.member lambda.name seen then
                                        ( seen, acc )

                                    else
                                        ( Set.insert lambda.name seen, acc ++ [ lambda ] )
                                )
                                ( Set.empty, [] )
                                lambdas
                    in
                    result

                ( lambdaOps, ctxAfter ) =
                    List.foldl
                        (\lambda ( accOps, accCtx ) ->
                            let
                                ( ops, newCtx ) =
                                    generateLambdaFunc accCtx lambda
                            in
                            ( accOps ++ ops, newCtx )
                        )
                        ( [], ctxCleared )
                        dedupedLambdas

                ( moreOps, finalCtx ) =
                    processLambdas ctxAfter
            in
            ( priorFuncOps ++ lambdaOps ++ moreOps, finalCtx )


generateLambdaFunc : Ctx.Context -> Ctx.PendingLambda -> ( List MlirOp, Ctx.Context )
generateLambdaFunc ctx lambda =
    let
        hasCaptures =
            not (List.isEmpty lambda.captures)

        -- Parameters use their actual MLIR types (typed calling convention)
        captureArgPairs : List ( String, MlirType )
        captureArgPairs =
            List.map (\( name, monoTy ) -> ( "%" ++ name, Types.monoTypeToAbi monoTy )) lambda.captures

        paramArgPairs : List ( String, MlirType )
        paramArgPairs =
            List.map (\( name, monoTy ) -> ( "%" ++ name, Types.monoTypeToAbi monoTy )) lambda.params

        allArgPairs : List ( String, MlirType )
        allArgPairs =
            captureArgPairs ++ paramArgPairs

        -- Build varMappings directly from typed parameters (no unboxing needed)
        -- Parameters arrive in their actual types due to typed calling convention.
        varMappingsWithArgs : Dict.Dict String Ctx.VarInfo
        varMappingsWithArgs =
            List.foldl
                (\( name, monoTy ) acc ->
                    let
                        mlirType =
                            Types.monoTypeToAbi monoTy

                        varName =
                            "%" ++ name
                    in
                    Dict.insert name
                        { ssaVar = varName
                        , mlirType = mlirType
                        }
                        acc
                )
                Dict.empty
                (lambda.captures ++ lambda.params)

        -- Initialize nextVar to account for all parameter SSA values
        nextVarAfterParams : Int
        nextVarAfterParams =
            List.length allArgPairs

        -- Merge sibling mappings with captures and params (captures/params take precedence)
        varMappingsWithSiblings : Dict.Dict String Ctx.VarInfo
        varMappingsWithSiblings =
            Dict.union varMappingsWithArgs lambda.siblingMappings

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | varMappings = varMappingsWithSiblings, nextVar = nextVarAfterParams }

        -- Actual return type from the lambda (typed ABI)
        actualResultType : MlirType
        actualResultType =
            Types.monoTypeToAbi lambda.returnType
    in
    if lambda.isTailRecursive then
        -- Tail-recursive lambda: use TailRec.compileTailFuncToWhile for the body.
        -- Only params participate in the loop state; captures are accessed from the
        -- enclosing func.func scope (scf.while is NOT IsolatedFromAbove).
        let
            ( bodyOps, ctx1 ) =
                TailRec.compileTailFuncToWhile ctxWithArgs lambda.name paramArgPairs lambda.body actualResultType

            ( bodyNonTermOps, bodyTerminator ) =
                case List.reverse bodyOps of
                    term :: rest ->
                        ( List.reverse rest, term )

                    [] ->
                        let
                            ( dummyOps, dummyVar, ctxDummy ) =
                                Expr.createDummyValue ctx1 actualResultType

                            ( _, dummyRetOp ) =
                                Ops.ecoReturn ctxDummy dummyVar actualResultType
                        in
                        ( dummyOps, dummyRetOp )

            funcBodyRegion : MlirRegion
            funcBodyRegion =
                Ops.mkRegion allArgPairs bodyNonTermOps bodyTerminator

            funcName =
                if hasCaptures then
                    lambda.name ++ "$cap"

                else
                    lambda.name

            ( ctx2, fastCloneOp ) =
                Ops.funcFunc ctx1 funcName allArgPairs actualResultType funcBodyRegion
        in
        if hasCaptures then
            let
                captureSpecs : List ( MlirType, Bool )
                captureSpecs =
                    List.map
                        (\( _, monoTy ) ->
                            let
                                mlirTy =
                                    Types.monoTypeToAbi monoTy
                            in
                            ( mlirTy, Types.isUnboxable mlirTy )
                        )
                        lambda.captures

                ( genericCloneOp, ctx3 ) =
                    Functions.generateGenericCloneFunc ctx2
                        (lambda.name ++ "$clo")
                        (lambda.name ++ "$cap")
                        captureSpecs
                        paramArgPairs
                        actualResultType
            in
            ( [ fastCloneOp, genericCloneOp ], ctx3 )

        else
            ( [ fastCloneOp ], ctx2 )

    else
        -- Regular (non-tail-recursive) lambda
        let
            exprResult : Expr.ExprResult
            exprResult =
                Expr.generateExpr ctxWithArgs lambda.body

            region : MlirRegion
            region =
                if exprResult.isTerminated then
                    Ops.mkRegionTerminatedByOps allArgPairs exprResult.ops

                else
                    let
                        ( coerceOps, finalVar, coerceCtx ) =
                            Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType actualResultType

                        ( _, returnOp ) =
                            Ops.ecoReturn coerceCtx finalVar actualResultType
                    in
                    Ops.mkRegion allArgPairs (exprResult.ops ++ coerceOps) returnOp

            funcName =
                if hasCaptures then
                    lambda.name ++ "$cap"

                else
                    lambda.name

            ( ctx2, fastCloneOp ) =
                Ops.funcFunc exprResult.ctx funcName allArgPairs actualResultType region
        in
        if hasCaptures then
            let
                captureSpecs : List ( MlirType, Bool )
                captureSpecs =
                    List.map
                        (\( _, monoTy ) ->
                            let
                                mlirTy =
                                    Types.monoTypeToAbi monoTy
                            in
                            ( mlirTy, Types.isUnboxable mlirTy )
                        )
                        lambda.captures

                ( genericCloneOp, ctx3 ) =
                    Functions.generateGenericCloneFunc ctx2
                        (lambda.name ++ "$clo")
                        (lambda.name ++ "$cap")
                        captureSpecs
                        paramArgPairs
                        actualResultType
            in
            ( [ fastCloneOp, genericCloneOp ], ctx3 )

        else
            ( [ fastCloneOp ], ctx2 )
