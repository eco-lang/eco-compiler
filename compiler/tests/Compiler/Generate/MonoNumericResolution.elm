module Compiler.Generate.MonoNumericResolution exposing
    ( expectNoNumericPolymorphism
    , expectNumericTypesResolved
    )

{-| Test logic for invariants:

  - MONO\_002: No CNumber MVar at MLIR codegen entry
  - MONO\_008: Primitive numeric types are fixed in calls

This module reuses the existing typed optimization pipeline to verify numeric type resolution.
The key verification is that monomorphization succeeds - which validates that all numeric
polymorphism is properly resolved before code generation.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| MONO\_002: Verify no CNumber MVars remain at MLIR codegen entry.
-}
expectNoNumericPolymorphism : Src.Module -> Expect.Expectation
expectNoNumericPolymorphism srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectCNumberIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| MONO\_008: Verify primitive numeric types are fixed in all calls.
-}
expectNumericTypesResolved : Src.Module -> Expect.Expectation
expectNumericTypesResolved srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectCallSiteNumericIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- CNUMBER ISSUE COLLECTION (MONO_002)
-- ============================================================================


{-| Collect all CNumber constraint issues in the graph.
-}
collectCNumberIssues : Mono.MonoGraph -> List String
collectCNumberIssues (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> collectNodeCNumberIssues specId node ++ acc)
        []
        data.nodes


{-| Collect CNumber issues from a single MonoNode.
-}
collectNodeCNumberIssues : Int -> Mono.MonoNode -> List String
collectNodeCNumberIssues specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) params
                ++ collectExprCNumberIssues context expr

        Mono.MonoCtor _ monoType ->
            checkForCNumber context monoType

        Mono.MonoEnum _ monoType ->
            checkForCNumber context monoType

        Mono.MonoExtern monoType ->
            checkForCNumber context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberIssues context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberIssues context expr

        Mono.MonoCycle defs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, expr ) -> collectExprCNumberIssues context expr) defs


{-| Collect CNumber issues from a MonoExpr.
-}
collectExprCNumberIssues : String -> Mono.MonoExpr -> List String
collectExprCNumberIssues context expr =
    case expr of
        Mono.MonoLiteral _ monoType ->
            checkForCNumber context monoType

        Mono.MonoVarLocal _ monoType ->
            checkForCNumber context monoType

        Mono.MonoVarGlobal _ _ monoType ->
            checkForCNumber context monoType

        Mono.MonoVarKernel _ _ _ monoType ->
            checkForCNumber context monoType

        Mono.MonoList _ exprs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (collectExprCNumberIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) closureInfo.params
                ++ List.concatMap (\( _, captureExpr, _ ) -> collectExprCNumberIssues context captureExpr) closureInfo.captures
                ++ collectExprCNumberIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberIssues context fnExpr
                ++ List.concatMap (collectExprCNumberIssues context) argExprs

        Mono.MonoTailCall _ args monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, argExpr ) -> collectExprCNumberIssues context argExpr) args

        Mono.MonoIf branches elseExpr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( condExpr, thenExpr ) -> collectExprCNumberIssues context condExpr ++ collectExprCNumberIssues context thenExpr) branches
                ++ collectExprCNumberIssues context elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            checkForCNumber context monoType
                ++ collectDefCNumberIssues context def
                ++ collectExprCNumberIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberIssues context valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, branchExpr ) -> collectExprCNumberIssues context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs _ monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (collectExprCNumberIssues context) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberIssues context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprCNumberIssues context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs _ monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (collectExprCNumberIssues context) elementExprs

        Mono.MonoUnit ->
            []


{-| Collect CNumber issues from a MonoDef.
-}
collectDefCNumberIssues : String -> Mono.MonoDef -> List String
collectDefCNumberIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            checkForCNumber context (Mono.typeOf expr)
                ++ collectExprCNumberIssues context expr

        Mono.MonoTailDef _ params expr ->
            checkForCNumber context (Mono.typeOf expr)
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) params
                ++ collectExprCNumberIssues context expr


{-| Check a MonoType for CNumber constraints.
-}
checkForCNumber : String -> Mono.MonoType -> List String
checkForCNumber context monoType =
    case monoType of
        Mono.MVar name Mono.CNumber ->
            [ context ++ ": Unresolved numeric type variable '" ++ name ++ "' with CNumber constraint" ]

        Mono.MVar _ Mono.CEcoValue ->
            []

        Mono.MList elemType ->
            checkForCNumber context elemType

        Mono.MCustom _ _ typeArgs ->
            List.concatMap (checkForCNumber context) typeArgs

        Mono.MFunction paramTypes returnType ->
            List.concatMap (checkForCNumber context) paramTypes
                ++ checkForCNumber context returnType

        _ ->
            []



-- ============================================================================
-- CALL SITE NUMERIC ISSUE COLLECTION (MONO_008)
-- ============================================================================


{-| Collect numeric type issues at call sites in the graph.
-}
collectCallSiteNumericIssues : Mono.MonoGraph -> List String
collectCallSiteNumericIssues (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> collectNodeCallSiteIssues specId node ++ acc)
        []
        data.nodes


{-| Collect call site issues from a single MonoNode.
-}
collectNodeCallSiteIssues : Int -> Mono.MonoNode -> List String
collectNodeCallSiteIssues specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprCallSiteIssues context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprCallSiteIssues context expr

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoPortIncoming expr _ ->
            collectExprCallSiteIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprCallSiteIssues context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, expr ) -> collectExprCallSiteIssues context expr) defs


{-| Collect call site issues from a MonoExpr, focusing on MonoCall and MonoTailCall.
-}
collectExprCallSiteIssues : String -> Mono.MonoExpr -> List String
collectExprCallSiteIssues context expr =
    case expr of
        Mono.MonoCall _ fnExpr argExprs _ ->
            -- Check that all numeric arguments are concrete MInt or MFloat
            let
                argIssues =
                    List.indexedMap
                        (\idx argExpr ->
                            let
                                argType =
                                    Mono.typeOf argExpr
                            in
                            checkNumericTypeResolved (context ++ ", call arg " ++ String.fromInt idx) argType
                        )
                        argExprs
                        |> List.concat
            in
            argIssues
                ++ collectExprCallSiteIssues context fnExpr
                ++ List.concatMap (collectExprCallSiteIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            -- Check that all arguments to tail calls have resolved numeric types
            let
                argIssues =
                    List.concatMap
                        (\( name, argExpr ) ->
                            let
                                argType =
                                    Mono.typeOf argExpr
                            in
                            checkNumericTypeResolved (context ++ ", tail call arg " ++ name) argType
                        )
                        args
            in
            argIssues
                ++ List.concatMap (\( _, argExpr ) -> collectExprCallSiteIssues context argExpr) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprCallSiteIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, captureExpr, _ ) -> collectExprCallSiteIssues context captureExpr) closureInfo.captures
                ++ collectExprCallSiteIssues context bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( condExpr, thenExpr ) -> collectExprCallSiteIssues context condExpr ++ collectExprCallSiteIssues context thenExpr) branches
                ++ collectExprCallSiteIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefCallSiteIssues context def
                ++ collectExprCallSiteIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprCallSiteIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, branchExpr ) -> collectExprCallSiteIssues context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs _ _ ->
            List.concatMap (collectExprCallSiteIssues context) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectExprCallSiteIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ _ ->
            collectExprCallSiteIssues context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprCallSiteIssues context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs _ _ ->
            List.concatMap (collectExprCallSiteIssues context) elementExprs

        _ ->
            []


{-| Collect call site issues from a MonoDef.
-}
collectDefCallSiteIssues : String -> Mono.MonoDef -> List String
collectDefCallSiteIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprCallSiteIssues context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprCallSiteIssues context expr


{-| Check if a type that appears in a numeric context is properly resolved.

For MONO\_008, numeric types at call sites must be concrete MInt or MFloat,
not polymorphic MVar CNumber.

-}
checkNumericTypeResolved : String -> Mono.MonoType -> List String
checkNumericTypeResolved context monoType =
    case monoType of
        Mono.MVar name Mono.CNumber ->
            [ context ++ ": Numeric type variable '" ++ name ++ "' not resolved to MInt or MFloat" ]

        Mono.MVar _ Mono.CEcoValue ->
            -- CEcoValue is fine - it's not a numeric constraint
            []

        Mono.MList elemType ->
            checkNumericTypeResolved context elemType

        Mono.MCustom _ _ typeArgs ->
            List.concatMap (checkNumericTypeResolved context) typeArgs

        Mono.MFunction paramTypes returnType ->
            List.concatMap (checkNumericTypeResolved context) paramTypes
                ++ checkNumericTypeResolved context returnType

        _ ->
            -- MInt, MFloat, MBool, MChar, MString, MUnit, MTuple, MRecord are all fine
            []
