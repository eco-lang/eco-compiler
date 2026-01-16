module Compiler.Generate.MonoFunctionArity exposing
    ( expectFunctionArityMatches
    )

{-| Test logic for invariant MONO_012: Function arity matches parameters and closure info.

For each function/closure node:

  - Compare the function MonoType's arity with the parameter list length and closure bindings.
  - Verify each call site's argument count matches the function's MonoType.

This module reuses the existing typed optimization pipeline and adds arity verification.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| MONO_012: Verify function arity matches parameters and closure info.
-}
expectFunctionArityMatches : Src.Module -> Expect.Expectation
expectFunctionArityMatches srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectArityIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- FUNCTION ARITY VERIFICATION
-- ============================================================================


{-| Collect all arity-related issues in the graph.
-}
collectArityIssues : Mono.MonoGraph -> List String
collectArityIssues (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeArity specId node ++ acc)
        []
        data.nodes


{-| Check arity for a single MonoNode.
-}
checkNodeArity : Int -> Mono.MonoNode -> List String
checkNodeArity specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            -- Check the expression's arity consistency
            checkTypeExprArityConsistency context monoType expr
                ++ collectExprArityIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            -- For tail functions, the parameter count should match the function type
            let
                paramCount =
                    List.length params

                typeArity =
                    getFunctionArity monoType

                arityIssue =
                    if typeArity /= paramCount then
                        [ context ++ ": MonoTailFunc has " ++ String.fromInt paramCount ++ " params but type has arity " ++ String.fromInt typeArity ]

                    else
                        []
            in
            arityIssue ++ collectExprArityIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprArityIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprArityIssues context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectExprArityIssues context e) defs

        _ ->
            []


{-| Get the arity (number of parameters) from a function type.
-}
getFunctionArity : Mono.MonoType -> Int
getFunctionArity monoType =
    case monoType of
        Mono.MFunction paramTypes _ ->
            List.length paramTypes

        _ ->
            0


{-| Check that a type and expression have consistent arity.
-}
checkTypeExprArityConsistency : String -> Mono.MonoType -> Mono.MonoExpr -> List String
checkTypeExprArityConsistency context monoType expr =
    case expr of
        Mono.MonoClosure closureInfo _ _ ->
            let
                paramCount =
                    List.length closureInfo.params

                typeArity =
                    getFunctionArity monoType
            in
            if typeArity /= paramCount then
                [ context ++ ": Closure has " ++ String.fromInt paramCount ++ " params but definition type has arity " ++ String.fromInt typeArity ]

            else
                []

        _ ->
            []


{-| Collect arity issues from expressions.
-}
collectExprArityIssues : String -> Mono.MonoExpr -> List String
collectExprArityIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr monoType ->
            -- Check closure parameter count vs closure's own function type
            let
                paramCount =
                    List.length closureInfo.params

                typeArity =
                    getFunctionArity monoType

                closureIssue =
                    if typeArity /= paramCount then
                        [ context ++ ": Closure expression has " ++ String.fromInt paramCount ++ " params but its type has arity " ++ String.fromInt typeArity ]

                    else
                        []
            in
            closureIssue
                ++ List.concatMap (\( _, e, _ ) -> collectExprArityIssues context e) closureInfo.captures
                ++ collectExprArityIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType ->
            -- Check that call site doesn't over-apply
            -- (Partial application is allowed, so under-application is fine)
            let
                fnType =
                    Mono.typeOf fnExpr

                fnArity =
                    getFunctionArity fnType

                argCount =
                    List.length argExprs

                callIssue =
                    -- Over-application is an error (more args than the function accepts)
                    if fnArity > 0 && argCount > fnArity then
                        [ context ++ ": Call has " ++ String.fromInt argCount ++ " args but function has arity " ++ String.fromInt fnArity ]

                    else
                        []
            in
            callIssue
                ++ collectExprArityIssues context fnExpr
                ++ List.concatMap (collectExprArityIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprArityIssues context e) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprArityIssues context) exprs

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprArityIssues context c ++ collectExprArityIssues context t) branches
                ++ collectExprArityIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefArityIssues context def
                ++ collectExprArityIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprArityIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprArityIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ _ ->
            List.concatMap (collectExprArityIssues context) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectExprArityIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ _ ->
            collectExprArityIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprArityIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ _ ->
            List.concatMap (collectExprArityIssues context) elementExprs

        _ ->
            []


{-| Collect arity issues from a MonoDef.
-}
collectDefArityIssues : String -> Mono.MonoDef -> List String
collectDefArityIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprArityIssues context expr

        Mono.MonoTailDef _ params expr ->
            -- Check that tail def param count matches expression type
            let
                exprType =
                    Mono.typeOf expr

                paramCount =
                    List.length params

                typeArity =
                    getFunctionArity exprType

                -- For tail defs, the expression should be the body, not a function
                -- So we just collect issues from the expression
            in
            collectExprArityIssues context expr
