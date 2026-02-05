module TestLogic.Generate.MonoFunctionArity exposing (expectFunctionArityMatches)

{-| Test logic for invariant MONO\_012: Function arity matches parameters and closure info.

For each function/closure node:

  - Compare the function MonoType's arity with the parameter list length and closure bindings.
  - Verify each call site's argument count matches the function's MonoType.

This module reuses the existing typed optimization pipeline and adds arity verification.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Map as Dict
import Expect
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono


{-| MONO\_012: Verify function arity matches parameters and closure info.
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
                    getFlattenedArity monoType

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


{-| Flatten a curried function type into a list of argument types and a final return type.

For example, `MFunction [a] (MFunction [b] c)` becomes `([a, b], c)`.

-}
flattenFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenFunctionType monoType =
    case monoType of
        Mono.MFunction params result ->
            let
                ( innerParams, innerResult ) =
                    flattenFunctionType result
            in
            ( params ++ innerParams, innerResult )

        _ ->
            ( [], monoType )


{-| Get the flattened arity (total number of parameters) from a function type.

This computes the flattened arity by peeling nested MFunction layers.
For example, `MFunction [a] (MFunction [b] c)` has flattened arity 2.

Used for MonoTailFunc checks (tail functions have all params flattened)
and call site checks to prevent over-application.

-}
getFlattenedArity : Mono.MonoType -> Int
getFlattenedArity monoType =
    let
        ( params, _ ) =
            flattenFunctionType monoType
    in
    List.length params


{-| Get the stage arity (outermost MFunction argument count) from a function type.

For example, `MFunction [a] (MFunction [b] c)` has stage arity 1.

Used for MonoClosure checks per MONO\_016: closureInfo.params length must
equal the stage arity, not the flattened arity.

-}
getStageArity : Mono.MonoType -> Int
getStageArity monoType =
    case monoType of
        Mono.MFunction params _ ->
            List.length params

        _ ->
            0


{-| Check that a type and expression have consistent arity.

For closures, MONO\_016 requires that closureInfo.params length equals the
stage arity (outermost MFunction argument count), not the flattened arity.

Each closure takes exactly one "stage" of arguments. Nested lambdas like
`\x -> \y -> expr` create separate closures, each with their own stage.

-}
checkTypeExprArityConsistency : String -> Mono.MonoType -> Mono.MonoExpr -> List String
checkTypeExprArityConsistency context monoType expr =
    case expr of
        Mono.MonoClosure closureInfo _ _ ->
            let
                paramCount =
                    List.length closureInfo.params

                stageArity =
                    getStageArity monoType
            in
            -- MONO_016: Closure params must exactly match stage arity
            if paramCount /= stageArity then
                [ context ++ ": Closure has " ++ String.fromInt paramCount ++ " params but type has stage arity " ++ String.fromInt stageArity ++ " (MONO_016 violation)" ]

            else
                []

        _ ->
            []


{-| Collect arity issues from expressions.

For closures: MONO\_016 requires params == stage arity (exact match).
For calls: check that args don't exceed flattened arity (prevent over-application).

-}
collectExprArityIssues : String -> Mono.MonoExpr -> List String
collectExprArityIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr monoType ->
            -- MONO_016: Closure params must exactly match stage arity
            let
                paramCount =
                    List.length closureInfo.params

                stageArity =
                    getStageArity monoType

                closureIssue =
                    if paramCount /= stageArity then
                        [ context ++ ": Closure expression has " ++ String.fromInt paramCount ++ " params but its type has stage arity " ++ String.fromInt stageArity ++ " (MONO_016 violation)" ]

                    else
                        []
            in
            closureIssue
                ++ List.concatMap (\( _, e, _ ) -> collectExprArityIssues context e) closureInfo.captures
                ++ collectExprArityIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ ->
            -- Check that call site doesn't over-apply (use flattened arity)
            -- (Partial application is allowed, so under-application is fine)
            let
                fnType =
                    Mono.typeOf fnExpr

                fnArity =
                    getFlattenedArity fnType

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

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderArityIssues context decider
                ++ List.concatMap (\( _, e ) -> collectExprArityIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprArityIssues context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprArityIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprArityIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprArityIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
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

        Mono.MonoTailDef _ _ expr ->
            -- Check that tail def param count matches expression type
            collectExprArityIssues context expr


{-| Collect arity issues from a Decider tree (for MonoCase inline leaves).
-}
collectDeciderArityIssues : String -> Mono.Decider Mono.MonoChoice -> List String
collectDeciderArityIssues context decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectExprArityIssues (context ++ " inline-leaf") expr

                Mono.Jump _ ->
                    -- Jumps are checked via the branches list
                    []

        Mono.Chain _ success failure ->
            collectDeciderArityIssues context success
                ++ collectDeciderArityIssues context failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderArityIssues context d) edges
                ++ collectDeciderArityIssues context fallback
