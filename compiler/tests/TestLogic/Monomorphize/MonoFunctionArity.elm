module TestLogic.Monomorphize.MonoFunctionArity exposing (expectMonoFunctionArity, checkMonoFunctionArity)

{-| Test logic for MONO\_012: Function arity matches parameters and closure info.

For each function/closure node at the Monomorphization phase:

  - Compare the function MonoType's flattened arity with the parameter list length.
  - Verify each call site's argument count does not exceed the function's flattened arity.

This test runs after Monomorphization (not GlobalOpt) to verify the invariant
at the correct phase. Stage arity checks (GOPT\_001) are separate and run after GlobalOpt.

@docs expectMonoFunctionArity, checkMonoFunctionArity

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Map as Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_012: Verify function arity matches parameters and closure info.
-}
expectMonoFunctionArity : Src.Module -> Expectation
expectMonoFunctionArity srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkMonoFunctionArity monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check function arity consistency for all nodes in the MonoGraph.
-}
checkMonoFunctionArity : Mono.MonoGraph -> List Violation
checkMonoFunctionArity (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeArity specId node ++ acc)
        []
        data.nodes


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n"



-- ============================================================================
-- MONO_012: FUNCTION ARITY VERIFICATION
-- ============================================================================


{-| Flatten a curried function type into a total parameter count.

For example, `MFunction [a] (MFunction [b] c)` has flattened arity 2.

-}
getFlattenedArity : Mono.MonoType -> Int
getFlattenedArity monoType =
    case monoType of
        Mono.MFunction params result ->
            List.length params + getFlattenedArity result

        _ ->
            0


{-| Check arity for a single MonoNode.
-}
checkNodeArity : Int -> Mono.MonoNode -> List Violation
checkNodeArity specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprArityIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            -- For tail functions, the parameter count should match the flattened function type
            let
                paramCount =
                    List.length params

                typeArity =
                    getFlattenedArity monoType

                arityIssue =
                    if typeArity /= paramCount then
                        [ { context = context
                          , message =
                                "MONO_012 violation: MonoTailFunc has "
                                    ++ String.fromInt paramCount
                                    ++ " params but type has flattened arity "
                                    ++ String.fromInt typeArity
                          }
                        ]

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


{-| Collect arity issues from expressions.

For calls: check that args don't exceed flattened arity (prevent over-application).

-}
collectExprArityIssues : String -> Mono.MonoExpr -> List Violation
collectExprArityIssues context expr =
    case expr of
        Mono.MonoCall _ fnExpr argExprs _ _ ->
            -- Check that call site doesn't over-apply (use flattened arity)
            let
                fnType =
                    Mono.typeOf fnExpr

                fnArity =
                    getFlattenedArity fnType

                argCount =
                    List.length argExprs

                callIssue =
                    -- Over-application is an error (more args than the function accepts total)
                    if fnArity > 0 && argCount > fnArity then
                        [ { context = context
                          , message =
                                "MONO_012 violation: Call has "
                                    ++ String.fromInt argCount
                                    ++ " args but function has flattened arity "
                                    ++ String.fromInt fnArity
                          }
                        ]

                    else
                        []
            in
            callIssue
                ++ collectExprArityIssues context fnExpr
                ++ List.concatMap (collectExprArityIssues context) argExprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectExprArityIssues context e) closureInfo.captures
                ++ collectExprArityIssues context bodyExpr

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
collectDefArityIssues : String -> Mono.MonoDef -> List Violation
collectDefArityIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprArityIssues context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprArityIssues context expr


{-| Collect arity issues from a Decider tree.
-}
collectDeciderArityIssues : String -> Mono.Decider Mono.MonoChoice -> List Violation
collectDeciderArityIssues context decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectExprArityIssues (context ++ " inline-leaf") expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectDeciderArityIssues context success
                ++ collectDeciderArityIssues context failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderArityIssues context d) edges
                ++ collectDeciderArityIssues context fallback
