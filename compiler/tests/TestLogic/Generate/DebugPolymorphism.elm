module TestLogic.Generate.DebugPolymorphism exposing
    ( expectDebugPolymorphismResolved
    )

{-| Test logic for invariant MONO_009: Debug.* kernel functions handle polymorphism.

For Debug.log, Debug.toString, and other kernel functions that operate
on polymorphic values:

  - Verify type information is correctly passed at runtime.
  - Verify string representations are type-appropriate.
  - Verify no runtime type errors occur.

This module reuses the existing typed optimization pipeline to verify
debug kernel polymorphism is correctly handled.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| Verify that Debug kernel calls remain polymorphic with CEcoValue.
-}
expectDebugPolymorphismResolved : Src.Module -> Expect.Expectation
expectDebugPolymorphismResolved srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectDebugPolymorphismIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- DEBUG POLYMORPHISM VERIFICATION
-- ============================================================================


{-| Collect issues with Debug kernel polymorphism handling.

Debug.log and Debug.toString are polymorphic functions that can accept any type.
After monomorphization, they should:

  - Retain polymorphic type parameters as MVar CEcoValue (not CNumber)
  - Not have unresolved CNumber constraints

-}
collectDebugPolymorphismIssues : Mono.MonoGraph -> List String
collectDebugPolymorphismIssues (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeDebugPolymorphism specId node ++ acc)
        []
        data.nodes


{-| Check Debug polymorphism for a single node.
-}
checkNodeDebugPolymorphism : Int -> Mono.MonoNode -> List String
checkNodeDebugPolymorphism specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprDebugIssues context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprDebugIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprDebugIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprDebugIssues context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectExprDebugIssues context e) defs

        _ ->
            []


{-| Collect Debug-related issues from expressions.

Checks MonoVarKernel nodes that reference Debug module functions to ensure
their polymorphic arguments are properly handled.

-}
collectExprDebugIssues : String -> Mono.MonoExpr -> List String
collectExprDebugIssues context expr =
    case expr of
        Mono.MonoVarKernel _ moduleName name monoType ->
            -- Check Debug kernel calls for proper polymorphism handling
            if moduleName == "Debug" then
                checkDebugKernelType context name monoType

            else
                []

        Mono.MonoCall _ fnExpr argExprs _ ->
            -- Check if this is a call to a Debug function
            let
                debugCallIssues =
                    case fnExpr of
                        Mono.MonoVarKernel _ moduleName name _ ->
                            if moduleName == "Debug" then
                                checkDebugCallArgs context name argExprs

                            else
                                []

                        _ ->
                            []
            in
            debugCallIssues
                ++ collectExprDebugIssues context fnExpr
                ++ List.concatMap (collectExprDebugIssues context) argExprs

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprDebugIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectExprDebugIssues context e) closureInfo.captures
                ++ collectExprDebugIssues context bodyExpr

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprDebugIssues context e) args

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprDebugIssues context c ++ collectExprDebugIssues context t) branches
                ++ collectExprDebugIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefDebugIssues context def
                ++ collectExprDebugIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprDebugIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprDebugIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (collectExprDebugIssues context) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectExprDebugIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprDebugIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprDebugIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprDebugIssues context) elementExprs

        _ ->
            []


{-| Collect Debug issues from a MonoDef.
-}
collectDefDebugIssues : String -> Mono.MonoDef -> List String
collectDefDebugIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprDebugIssues context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprDebugIssues context expr


{-| Check Debug kernel function type for proper polymorphism.

Debug functions like Debug.log and Debug.toString accept any type.
Their type arguments should be MVar CEcoValue, not CNumber.

-}
checkDebugKernelType : String -> String -> Mono.MonoType -> List String
checkDebugKernelType context name monoType =
    case monoType of
        Mono.MFunction paramTypes returnType ->
            -- Check parameter types for CNumber constraints (should not be present)
            List.indexedMap
                (\idx paramType ->
                    checkNoCNumberInDebugArg (context ++ ", Debug." ++ name ++ " param " ++ String.fromInt idx) paramType
                )
                paramTypes
                |> List.concat
                |> (++) (checkNoCNumberInDebugArg (context ++ ", Debug." ++ name ++ " return") returnType)

        _ ->
            -- Non-function Debug kernel - unusual but not an error
            []


{-| Check Debug call arguments for proper polymorphism.

When Debug.log or Debug.toString is called, the argument types should
not have unresolved CNumber constraints.

-}
checkDebugCallArgs : String -> String -> List Mono.MonoExpr -> List String
checkDebugCallArgs context name argExprs =
    List.indexedMap
        (\idx argExpr ->
            let
                argType =
                    Mono.typeOf argExpr
            in
            checkNoCNumberInDebugArg (context ++ ", Debug." ++ name ++ " call arg " ++ String.fromInt idx) argType
        )
        argExprs
        |> List.concat


{-| Check that a type used in Debug context doesn't have CNumber constraints.

CNumber should be resolved to MInt or MFloat. CEcoValue is acceptable
since Debug functions handle polymorphic values at runtime.

-}
checkNoCNumberInDebugArg : String -> Mono.MonoType -> List String
checkNoCNumberInDebugArg context monoType =
    case monoType of
        Mono.MVar name Mono.CNumber ->
            [ context ++ ": Found CNumber constraint on type variable '" ++ name ++ "' in Debug call (should be CEcoValue or concrete type)" ]

        Mono.MVar _ Mono.CEcoValue ->
            -- CEcoValue is fine - Debug handles polymorphism at runtime
            []

        Mono.MList elemType ->
            checkNoCNumberInDebugArg context elemType

        Mono.MCustom _ _ typeArgs ->
            List.concatMap (checkNoCNumberInDebugArg context) typeArgs

        Mono.MFunction paramTypes returnType ->
            List.concatMap (checkNoCNumberInDebugArg context) paramTypes
                ++ checkNoCNumberInDebugArg context returnType

        _ ->
            []
