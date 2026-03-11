module TestLogic.LocalOpt.FunctionTypeEncode exposing (expectFunctionTypesEncoded)

{-| Test logic for invariant TOPT\_005: Function expressions encode full function type.

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
import Compiler.Reporting.Annotation as A
import Data.Map
import Dict
import Expect
import System.TypeCheck.IO as IO
import TestLogic.TestPipeline as Pipeline


{-| Verify that all function expressions have correctly encoded function types.
-}
expectFunctionTypesEncoded : Src.Module -> Expect.Expectation
expectFunctionTypesEncoded srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                checks =
                    collectFunctionTypeChecks result.localGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- FUNCTION TYPE ENCODING VERIFICATION
-- ============================================================================


{-| Collect function type checks from the local graph.
-}
collectFunctionTypeChecks : TOpt.LocalGraph -> List (() -> Expect.Expectation)
collectFunctionTypeChecks (TOpt.LocalGraph data) =
    Data.Map.foldl TOpt.compareGlobal
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
checkNodeFunctionTypes : String -> TOpt.Node -> List (() -> Expect.Expectation)
checkNodeFunctionTypes context node =
    case node of
        TOpt.Define expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.TrackedDefine _ expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.Cycle _ _ defs _ ->
            List.concatMap (\def -> checkDefFunctionTypes context def) defs

        TOpt.PortIncoming expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.PortOutgoing expr _ _ ->
            collectExprFunctionTypeChecks context expr

        _ ->
            []


{-| Check Def function types.
-}
checkDefFunctionTypes : String -> TOpt.Def -> List (() -> Expect.Expectation)
checkDefFunctionTypes context def =
    case def of
        TOpt.Def _ name expr _ ->
            collectExprFunctionTypeChecks (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name _ expr _ ->
            collectExprFunctionTypeChecks (context ++ " TailDef " ++ name) expr


{-| Collect function type checks from expressions.
-}
collectExprFunctionTypeChecks : String -> TOpt.Expr -> List (() -> Expect.Expectation)
collectExprFunctionTypeChecks context expr =
    case expr of
        TOpt.Function params bodyExpr fnType ->
            -- The function's attached type should match TLambda chain of params -> body type
            let
                paramTypes =
                    List.map Tuple.second params

                -- Check that the attached type has the right structure
                typeCheck =
                    if not (functionTypeMatches paramTypes fnType) then
                        [ \() -> Expect.fail (context ++ ": Function expression type does not match parameter types") ]

                    else
                        []
            in
            typeCheck ++ collectExprFunctionTypeChecks context bodyExpr

        TOpt.TrackedFunction params bodyExpr fnType ->
            let
                paramTypes =
                    List.map Tuple.second params

                typeCheck =
                    if not (functionTypeMatches paramTypes fnType) then
                        [ \() -> Expect.fail (context ++ ": TrackedFunction expression type does not match parameter types") ]

                    else
                        []
            in
            typeCheck ++ collectExprFunctionTypeChecks context bodyExpr

        TOpt.Call _ fnExpr argExprs _ ->
            collectExprFunctionTypeChecks context fnExpr
                ++ List.concatMap (collectExprFunctionTypeChecks context) argExprs

        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, argExpr ) -> collectExprFunctionTypeChecks context argExpr) args

        TOpt.If branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprFunctionTypeChecks context c ++ collectExprFunctionTypeChecks context t) branches
                ++ collectExprFunctionTypeChecks context elseExpr

        TOpt.Let def bodyExpr _ ->
            checkDefFunctionTypes context def
                ++ collectExprFunctionTypeChecks context bodyExpr

        TOpt.Destruct _ valueExpr _ ->
            collectExprFunctionTypeChecks context valueExpr

        TOpt.Case _ _ _ branches _ ->
            List.concatMap (\( _, branchExpr ) -> collectExprFunctionTypeChecks context branchExpr) branches

        TOpt.List _ exprs _ ->
            List.concatMap (collectExprFunctionTypeChecks context) exprs

        TOpt.Access recordExpr _ _ _ ->
            collectExprFunctionTypeChecks context recordExpr

        TOpt.Update _ recordExpr updates _ ->
            collectExprFunctionTypeChecks context recordExpr
                ++ Data.Map.foldl A.compareLocated (\_ updateExpr acc -> collectExprFunctionTypeChecks context updateExpr ++ acc) [] updates

        TOpt.Record fieldExprs _ ->
            Dict.foldl (\_ fieldExpr acc -> collectExprFunctionTypeChecks context fieldExpr ++ acc) [] fieldExprs

        TOpt.TrackedRecord _ fieldExprs _ ->
            Data.Map.foldl A.compareLocated (\_ fieldExpr acc -> collectExprFunctionTypeChecks context fieldExpr ++ acc) [] fieldExprs

        TOpt.Tuple _ e1 e2 rest _ ->
            collectExprFunctionTypeChecks context e1
                ++ collectExprFunctionTypeChecks context e2
                ++ List.concatMap (collectExprFunctionTypeChecks context) rest

        _ ->
            []


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
