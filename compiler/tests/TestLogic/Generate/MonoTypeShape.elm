module TestLogic.Generate.MonoTypeShape exposing (expectMonoTypesFullyElaborated)

{-| Test logic for invariant MONO\_001: MonoTypes are fully elaborated.

At all stages past monomorphization, every type has a concrete MonoType shape:
MInt, MFloat, MBool, MChar, MString, MUnit, MList, MTuple, MRecord, MCustom,
MFunction. MVar should only appear with constraint CEcoValue.

This module reuses the existing typed optimization pipeline to verify
that monomorphization produces valid MonoTypes.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Map as Dict
import Expect
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono


{-| MONO\_001: Verify all MonoTypes are fully elaborated.
-}
expectMonoTypesFullyElaborated : Src.Module -> Expect.Expectation
expectMonoTypesFullyElaborated srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectMonoTypeIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- MONO TYPE TRAVERSAL
-- ============================================================================


{-| Collect all issues with MonoTypes in the graph.
-}
collectMonoTypeIssues : Mono.MonoGraph -> List String
collectMonoTypeIssues (Mono.MonoGraph data) =
    -- Traverse all nodes and collect types from each
    Dict.foldl compare
        (\specId node acc -> collectNodeTypeIssues specId node ++ acc)
        []
        data.nodes


{-| Collect type issues from a single MonoNode.
-}
collectNodeTypeIssues : Int -> Mono.MonoNode -> List String
collectNodeTypeIssues specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, paramType ) -> checkMonoType context paramType) params
                ++ collectExprTypeIssues context expr

        Mono.MonoCtor _ monoType ->
            checkMonoType context monoType

        Mono.MonoEnum _ monoType ->
            checkMonoType context monoType

        Mono.MonoExtern monoType ->
            checkMonoType context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context expr

        Mono.MonoCycle defs monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, expr ) -> collectExprTypeIssues context expr) defs


{-| Collect type issues from a MonoExpr.
-}
collectExprTypeIssues : String -> Mono.MonoExpr -> List String
collectExprTypeIssues context expr =
    case expr of
        Mono.MonoLiteral _ monoType ->
            checkMonoType context monoType

        Mono.MonoVarLocal _ monoType ->
            checkMonoType context monoType

        Mono.MonoVarGlobal _ _ monoType ->
            checkMonoType context monoType

        Mono.MonoVarKernel _ _ _ monoType ->
            checkMonoType context monoType

        Mono.MonoList _ exprs monoType ->
            checkMonoType context monoType
                ++ List.concatMap (collectExprTypeIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, paramType ) -> checkMonoType context paramType) closureInfo.params
                ++ List.concatMap (\( _, captureExpr, _ ) -> collectExprTypeIssues context captureExpr) closureInfo.captures
                ++ collectExprTypeIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context fnExpr
                ++ List.concatMap (collectExprTypeIssues context) argExprs

        Mono.MonoTailCall _ args monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, argExpr ) -> collectExprTypeIssues context argExpr) args

        Mono.MonoIf branches elseExpr monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( condExpr, thenExpr ) -> collectExprTypeIssues context condExpr ++ collectExprTypeIssues context thenExpr) branches
                ++ collectExprTypeIssues context elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            checkMonoType context monoType
                ++ collectDefTypeIssues context def
                ++ collectExprTypeIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, branchExpr ) -> collectExprTypeIssues context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, e ) -> collectExprTypeIssues context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprTypeIssues context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs monoType ->
            checkMonoType context monoType
                ++ List.concatMap (collectExprTypeIssues context) elementExprs

        Mono.MonoUnit ->
            []


{-| Collect type issues from a MonoDef.
-}
collectDefTypeIssues : String -> Mono.MonoDef -> List String
collectDefTypeIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            checkMonoType context (Mono.typeOf expr)
                ++ collectExprTypeIssues context expr

        Mono.MonoTailDef _ params expr ->
            checkMonoType context (Mono.typeOf expr)
                ++ List.concatMap (\( _, paramType ) -> checkMonoType context paramType) params
                ++ collectExprTypeIssues context expr


{-| Check a MonoType for elaboration issues.

Returns list of issue descriptions. Empty list means the type is valid.

MONO\_001 rule: MVar is only allowed with CEcoValue constraint.
MVar with CNumber means numeric polymorphism wasn't resolved.

-}
checkMonoType : String -> Mono.MonoType -> List String
checkMonoType context monoType =
    case monoType of
        Mono.MInt ->
            []

        Mono.MFloat ->
            []

        Mono.MBool ->
            []

        Mono.MChar ->
            []

        Mono.MString ->
            []

        Mono.MUnit ->
            []

        Mono.MList elemType ->
            checkMonoType context elemType

        Mono.MTuple _ ->
            -- Tuple layout types are already elaborated
            []

        Mono.MRecord _ ->
            -- Record layout types are already elaborated
            []

        Mono.MCustom _ _ typeArgs ->
            List.concatMap (checkMonoType context) typeArgs

        Mono.MFunction paramTypes returnType ->
            List.concatMap (checkMonoType context) paramTypes
                ++ checkMonoType context returnType

        Mono.MVar name constraint ->
            case constraint of
                Mono.CEcoValue ->
                    -- CEcoValue is allowed - it's a polymorphic type that doesn't affect layout
                    []

                Mono.CNumber ->
                    -- CNumber should be resolved to MInt or MFloat after monomorphization
                    [ context ++ ": Found unresolved numeric type variable '" ++ name ++ "' with CNumber constraint" ]
