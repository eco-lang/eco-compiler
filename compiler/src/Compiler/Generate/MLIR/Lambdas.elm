module Compiler.Generate.MLIR.Lambdas exposing (processLambdas)

{-| Lambda processing for the MLIR backend.

This module handles processing pending lambdas into func.func ops
with typed ABIs (parameters in their actual types, not all boxed).

@docs processLambdas

-}

import Compiler.Data.Name exposing (Name)
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Compiler.Monomorphize.Closure as Closure
import Data.Set as EverySet exposing (EverySet)
import Dict
import Mlir.Mlir exposing (MlirOp, MlirRegion, MlirType)
import Utils.Crash exposing (crash)



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
                                _ =
                                    validatePendingLambdaFreeVars lambda

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


{-| Validate CGEN\_CLOSURE\_003: all free variables in a lambda body must be
in params, captures, or siblingMappings.
-}
validatePendingLambdaFreeVars : Ctx.PendingLambda -> ()
validatePendingLambdaFreeVars lambda =
    let
        paramNames =
            List.map Tuple.first lambda.params

        captureNames =
            List.map Tuple.first lambda.captures

        siblingNames =
            Dict.keys lambda.siblingMappings

        allowed =
            EverySet.fromList identity (paramNames ++ captureNames ++ siblingNames)

        -- Compute free variables of the body with empty initial bound,
        -- then filter against allowed names
        freeInBody =
            Closure.findFreeLocals EverySet.empty lambda.body

        badFreeVars =
            List.filter (\name -> not (EverySet.member identity name allowed)) freeInBody
    in
    case badFreeVars of
        [] ->
            ()

        _ ->
            crash
                ("CGEN_CLOSURE_003 violated for lambda "
                    ++ lambda.name
                    ++ ": free variables not in params/captures/siblings = ["
                    ++ String.join ", " badFreeVars
                    ++ "]"
                )


generateLambdaFunc : Ctx.Context -> Ctx.PendingLambda -> ( MlirOp, Ctx.Context )
generateLambdaFunc ctx lambda =
    let
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

        -- No unboxOps needed - parameters arrive in their actual types
        unboxOps : List MlirOp
        unboxOps =
            []

        -- Merge sibling mappings with captures and params (captures/params take precedence)
        varMappingsWithSiblings : Dict.Dict String Ctx.VarInfo
        varMappingsWithSiblings =
            Dict.union varMappingsWithArgs lambda.siblingMappings

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | varMappings = varMappingsWithSiblings, nextVar = nextVarAfterParams }

        exprResult : Expr.ExprResult
        exprResult =
            Expr.generateExpr ctxWithArgs lambda.body

        -- Actual return type from the lambda (typed ABI)
        actualResultType : MlirType
        actualResultType =
            Types.monoTypeToAbi lambda.returnType

        region : MlirRegion
        region =
            if exprResult.isTerminated then
                -- Expression is a control-flow exit (eco.case, eco.jump).
                -- The ops already contain the terminator - don't add eco.return.
                -- IMPORTANT: Do NOT access exprResult.resultVar here - it is meaningless!
                Ops.mkRegionTerminatedByOps allArgPairs (unboxOps ++ exprResult.ops)

            else
                -- Normal expression - coerce result to ABI return type if needed, then add eco.return.
                -- This handles cases like Bool where SSA type is i1 but ABI return type is eco.value.
                let
                    ( coerceOps, finalVar, coerceCtx ) =
                        Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType actualResultType

                    ( _, returnOp ) =
                        Ops.ecoReturn coerceCtx finalVar actualResultType
                in
                Ops.mkRegion allArgPairs (unboxOps ++ exprResult.ops ++ coerceOps) returnOp

        ( ctx2, funcOp ) =
            Ops.funcFunc exprResult.ctx lambda.name allArgPairs actualResultType region
    in
    ( funcOp, ctx2 )
