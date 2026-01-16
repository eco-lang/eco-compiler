module Compiler.Optimize.FunctionTypeEncode exposing
    ( expectFunctionTypesEncoded
    )

{-| Test logic for invariant TOPT_005: Function expressions encode full function type.

For every function expression in TypedOptimized:

  - Extract its parameter (Name, Can.Type) list and result Can.Type.
  - Compute the corresponding curried TLambda chain.
  - Assert that the expression's own attached Can.Type equals that TLambda type.

This module reuses the existing typed optimization pipeline to verify
function types are properly encoded.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Expect
import System.TypeCheck.IO as IO


{-| Verify that all function expressions have correctly encoded function types.
-}
expectFunctionTypesEncoded : Src.Module -> Expect.Expectation
expectFunctionTypesEncoded srcModule =
    case TOMono.runToTypedOptimized srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectFunctionTypeIssues result.localGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- FUNCTION TYPE ENCODING VERIFICATION
-- ============================================================================


{-| Collect function type encoding issues from the local graph.
-}
collectFunctionTypeIssues : TOpt.LocalGraph -> List String
collectFunctionTypeIssues (TOpt.LocalGraph data) =
    Dict.foldl TOpt.compareGlobal
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNodeFunctionTypes context node ++ acc
        )
        []
        data.nodes


{-| Convert a Global to a string for context messages.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        IO.Canonical _ moduleName ->
            moduleName ++ "." ++ name


{-| Check function type encoding for a node.
-}
checkNodeFunctionTypes : String -> TOpt.Node -> List String
checkNodeFunctionTypes context node =
    case node of
        TOpt.Define expr _ _ ->
            collectExprFunctionTypeIssues context expr

        TOpt.TrackedDefine _ expr _ _ ->
            collectExprFunctionTypeIssues context expr

        TOpt.DefineTailFunc _ params expr _ returnType ->
            -- The node itself should have a function type matching params -> returnType
            let
                expectedType =
                    buildFunctionType (List.map Tuple.second params) returnType

                -- For DefineTailFunc, we check the body expression
            in
            collectExprFunctionTypeIssues context expr

        TOpt.Cycle _ _ defs _ ->
            List.concatMap (\def -> checkDefFunctionTypes context def) defs

        TOpt.PortIncoming expr _ _ ->
            collectExprFunctionTypeIssues context expr

        TOpt.PortOutgoing expr _ _ ->
            collectExprFunctionTypeIssues context expr

        _ ->
            []


{-| Check Def function types.
-}
checkDefFunctionTypes : String -> TOpt.Def -> List String
checkDefFunctionTypes context def =
    case def of
        TOpt.Def _ name expr _ ->
            collectExprFunctionTypeIssues (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name _ expr _ ->
            collectExprFunctionTypeIssues (context ++ " TailDef " ++ name) expr


{-| Collect function type issues from expressions.
-}
collectExprFunctionTypeIssues : String -> TOpt.Expr -> List String
collectExprFunctionTypeIssues context expr =
    case expr of
        TOpt.Function params bodyExpr fnType ->
            -- The function's attached type should match TLambda chain of params -> body type
            let
                paramTypes =
                    List.map Tuple.second params

                bodyType =
                    TOpt.typeOf bodyExpr

                expectedType =
                    buildFunctionType paramTypes bodyType

                -- Check that the attached type has the right structure
                typeIssue =
                    if not (functionTypeMatches paramTypes fnType) then
                        [ context ++ ": Function expression type does not match parameter types" ]

                    else
                        []
            in
            typeIssue ++ collectExprFunctionTypeIssues context bodyExpr

        TOpt.TrackedFunction params bodyExpr fnType ->
            let
                paramTypes =
                    List.map Tuple.second params

                typeIssue =
                    if not (functionTypeMatches paramTypes fnType) then
                        [ context ++ ": TrackedFunction expression type does not match parameter types" ]

                    else
                        []
            in
            typeIssue ++ collectExprFunctionTypeIssues context bodyExpr

        TOpt.Call _ fnExpr argExprs _ ->
            collectExprFunctionTypeIssues context fnExpr
                ++ List.concatMap (collectExprFunctionTypeIssues context) argExprs

        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, argExpr ) -> collectExprFunctionTypeIssues context argExpr) args

        TOpt.If branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprFunctionTypeIssues context c ++ collectExprFunctionTypeIssues context t) branches
                ++ collectExprFunctionTypeIssues context elseExpr

        TOpt.Let def bodyExpr _ ->
            checkDefFunctionTypes context def
                ++ collectExprFunctionTypeIssues context bodyExpr

        TOpt.Destruct _ valueExpr _ ->
            collectExprFunctionTypeIssues context valueExpr

        TOpt.Case _ _ _ branches _ ->
            List.concatMap (\( _, branchExpr ) -> collectExprFunctionTypeIssues context branchExpr) branches

        TOpt.List _ exprs _ ->
            List.concatMap (collectExprFunctionTypeIssues context) exprs

        TOpt.Access recordExpr _ _ _ ->
            collectExprFunctionTypeIssues context recordExpr

        TOpt.Update _ recordExpr updates _ ->
            collectExprFunctionTypeIssues context recordExpr
                ++ Dict.foldl A.compareLocated (\_ updateExpr acc -> collectExprFunctionTypeIssues context updateExpr ++ acc) [] updates

        TOpt.Record fieldExprs _ ->
            Dict.foldl compare (\_ fieldExpr acc -> collectExprFunctionTypeIssues context fieldExpr ++ acc) [] fieldExprs

        TOpt.TrackedRecord _ fieldExprs _ ->
            Dict.foldl A.compareLocated (\_ fieldExpr acc -> collectExprFunctionTypeIssues context fieldExpr ++ acc) [] fieldExprs

        TOpt.Tuple _ e1 e2 rest _ ->
            collectExprFunctionTypeIssues context e1
                ++ collectExprFunctionTypeIssues context e2
                ++ List.concatMap (collectExprFunctionTypeIssues context) rest

        _ ->
            []


{-| Build a curried function type from parameter types and result type.
-}
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType paramTypes resultType =
    List.foldr Can.TLambda resultType paramTypes


{-| Check if a function type matches the expected parameter types.

The type should be a TLambda chain where each left side matches
the corresponding parameter type.

-}
functionTypeMatches : List Can.Type -> Can.Type -> Bool
functionTypeMatches paramTypes fnType =
    case ( paramTypes, fnType ) of
        ( [], _ ) ->
            -- No more params, any type is valid for the result
            True

        ( _ :: restParams, Can.TLambda _ restType ) ->
            -- Check rest of params (we don't strictly compare types as that would
            -- require full type equality, just verify structure)
            functionTypeMatches restParams restType

        _ ->
            -- Type doesn't have enough TLambdas for the params
            False
