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
                checks =
                    collectCNumberChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| MONO\_008: Verify primitive numeric types are fixed in all calls.
-}
expectNumericTypesResolved : Src.Module -> Expect.Expectation
expectNumericTypesResolved srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                checks =
                    collectCallSiteNumericChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- CNUMBER ISSUE COLLECTION (MONO_002)
-- ============================================================================


{-| Collect all CNumber constraint checks in the graph.
-}
collectCNumberChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCNumberChecks (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> collectNodeCNumberChecks specId node ++ acc)
        []
        data.nodes


{-| Collect CNumber checks from a single MonoNode.
-}
collectNodeCNumberChecks : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
collectNodeCNumberChecks specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context expr

        Mono.MonoTailFunc params expr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) params
                ++ collectExprCNumberChecks context expr

        Mono.MonoCtor _ monoType ->
            checkForCNumber context monoType

        Mono.MonoEnum _ monoType ->
            checkForCNumber context monoType

        Mono.MonoExtern monoType ->
            checkForCNumber context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context expr

        Mono.MonoCycle defs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, expr ) -> collectExprCNumberChecks context expr) defs


{-| Collect CNumber checks from a MonoExpr.
-}
collectExprCNumberChecks : String -> Mono.MonoExpr -> List (() -> Expect.Expectation)
collectExprCNumberChecks context expr =
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
                ++ List.concatMap (collectExprCNumberChecks context) exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) closureInfo.params
                ++ List.concatMap (\( _, captureExpr, _ ) -> collectExprCNumberChecks context captureExpr) closureInfo.captures
                ++ collectExprCNumberChecks context bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context fnExpr
                ++ List.concatMap (collectExprCNumberChecks context) argExprs

        Mono.MonoTailCall _ args monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, argExpr ) -> collectExprCNumberChecks context argExpr) args

        Mono.MonoIf branches elseExpr monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( condExpr, thenExpr ) -> collectExprCNumberChecks context condExpr ++ collectExprCNumberChecks context thenExpr) branches
                ++ collectExprCNumberChecks context elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            checkForCNumber context monoType
                ++ collectDefCNumberChecks context def
                ++ collectExprCNumberChecks context bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (\( _, branchExpr ) -> collectExprCNumberChecks context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (collectExprCNumberChecks context) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context recordExpr

        Mono.MonoRecordUpdate recordExpr updates monoType ->
            checkForCNumber context monoType
                ++ collectExprCNumberChecks context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprCNumberChecks context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs monoType ->
            checkForCNumber context monoType
                ++ List.concatMap (collectExprCNumberChecks context) elementExprs

        Mono.MonoUnit ->
            []


{-| Collect CNumber checks from a MonoDef.
-}
collectDefCNumberChecks : String -> Mono.MonoDef -> List (() -> Expect.Expectation)
collectDefCNumberChecks context def =
    case def of
        Mono.MonoDef _ expr ->
            checkForCNumber context (Mono.typeOf expr)
                ++ collectExprCNumberChecks context expr

        Mono.MonoTailDef _ params expr ->
            checkForCNumber context (Mono.typeOf expr)
                ++ List.concatMap (\( _, paramType ) -> checkForCNumber context paramType) params
                ++ collectExprCNumberChecks context expr


{-| Check a MonoType for CNumber constraints.
-}
checkForCNumber : String -> Mono.MonoType -> List (() -> Expect.Expectation)
checkForCNumber context monoType =
    case monoType of
        Mono.MVar name Mono.CNumber ->
            [ \() -> Expect.fail (context ++ ": Unresolved numeric type variable '" ++ name ++ "' with CNumber constraint") ]

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


{-| Collect numeric type checks at call sites in the graph.
-}
collectCallSiteNumericChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCallSiteNumericChecks (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> collectNodeCallSiteChecks specId node ++ acc)
        []
        data.nodes


{-| Collect call site checks from a single MonoNode.
-}
collectNodeCallSiteChecks : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
collectNodeCallSiteChecks specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprCallSiteChecks context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprCallSiteChecks context expr

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoPortIncoming expr _ ->
            collectExprCallSiteChecks context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprCallSiteChecks context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, expr ) -> collectExprCallSiteChecks context expr) defs


{-| Collect call site checks from a MonoExpr, focusing on MonoCall and MonoTailCall.
-}
collectExprCallSiteChecks : String -> Mono.MonoExpr -> List (() -> Expect.Expectation)
collectExprCallSiteChecks context expr =
    case expr of
        Mono.MonoCall _ fnExpr argExprs _ ->
            -- Check that all numeric arguments are concrete MInt or MFloat
            let
                argChecks =
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
            argChecks
                ++ collectExprCallSiteChecks context fnExpr
                ++ List.concatMap (collectExprCallSiteChecks context) argExprs

        Mono.MonoTailCall _ args _ ->
            -- Check that all arguments to tail calls have resolved numeric types
            let
                argChecks =
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
            argChecks
                ++ List.concatMap (\( _, argExpr ) -> collectExprCallSiteChecks context argExpr) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprCallSiteChecks context) exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, captureExpr, _ ) -> collectExprCallSiteChecks context captureExpr) closureInfo.captures
                ++ collectExprCallSiteChecks context bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( condExpr, thenExpr ) -> collectExprCallSiteChecks context condExpr ++ collectExprCallSiteChecks context thenExpr) branches
                ++ collectExprCallSiteChecks context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefCallSiteChecks context def
                ++ collectExprCallSiteChecks context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprCallSiteChecks context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, branchExpr ) -> collectExprCallSiteChecks context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (collectExprCallSiteChecks context) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectExprCallSiteChecks context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprCallSiteChecks context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprCallSiteChecks context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprCallSiteChecks context) elementExprs

        _ ->
            []


{-| Collect call site checks from a MonoDef.
-}
collectDefCallSiteChecks : String -> Mono.MonoDef -> List (() -> Expect.Expectation)
collectDefCallSiteChecks context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprCallSiteChecks context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprCallSiteChecks context expr


{-| Check if a type that appears in a numeric context is properly resolved.

For MONO\_008, numeric types at call sites must be concrete MInt or MFloat,
not polymorphic MVar CNumber.

-}
checkNumericTypeResolved : String -> Mono.MonoType -> List (() -> Expect.Expectation)
checkNumericTypeResolved context monoType =
    case monoType of
        Mono.MVar name Mono.CNumber ->
            [ \() -> Expect.fail (context ++ ": Numeric type variable '" ++ name ++ "' not resolved to MInt or MFloat") ]

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
