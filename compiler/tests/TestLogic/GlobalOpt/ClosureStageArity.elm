module TestLogic.GlobalOpt.ClosureStageArity exposing
    ( expectClosureStageArity, checkClosureStageArity
    , Violation
    )

{-| Test logic for GOPT\_001: Closure params match stage arity.

For every MonoClosure with function type MFunction after GlobalOpt, the length
of closureInfo.params must equal the length of the outermost MFunction param list
(stage arity).

This is established by canonicalizeClosureStaging in GlobalOpt.

@docs expectClosureStageArity, checkClosureStageArity

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


{-| GOPT\_001: Verify closure params match stage arity after GlobalOpt.
-}
expectClosureStageArity : Src.Module -> Expectation
expectClosureStageArity srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                violations =
                    checkClosureStageArity optimizedMonoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check closure stage arity for all closures in the MonoGraph.
-}
checkClosureStageArity : Mono.MonoGraph -> List Violation
checkClosureStageArity (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeClosures specId node ++ acc)
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
-- GOPT_001: CLOSURE STAGE ARITY VERIFICATION
-- ============================================================================


{-| Get the stage arity from a function type (outermost MFunction arg count).
-}
getStageArity : Mono.MonoType -> Int
getStageArity monoType =
    case monoType of
        Mono.MFunction params _ ->
            List.length params

        _ ->
            0


{-| Check closures in a single MonoNode.
-}
checkNodeClosures : Int -> Mono.MonoNode -> List Violation
checkNodeClosures specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            -- Check top-level expression's type/expr consistency
            checkTypeExprConsistency context monoType expr
                ++ collectExprClosureIssues context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprClosureIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprClosureIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprClosureIssues context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectExprClosureIssues context e) defs

        _ ->
            []


{-| Check that a type and expression have consistent arity.
-}
checkTypeExprConsistency : String -> Mono.MonoType -> Mono.MonoExpr -> List Violation
checkTypeExprConsistency context monoType expr =
    case expr of
        Mono.MonoClosure closureInfo _ _ ->
            let
                paramCount =
                    List.length closureInfo.params

                stageArity =
                    getStageArity monoType
            in
            if paramCount /= stageArity then
                [ { context = context
                  , message =
                        "GOPT_001 violation: Closure has "
                            ++ String.fromInt paramCount
                            ++ " params but type has stage arity "
                            ++ String.fromInt stageArity
                  }
                ]

            else
                []

        _ ->
            []


{-| Collect closure issues from expressions.
-}
collectExprClosureIssues : String -> Mono.MonoExpr -> List Violation
collectExprClosureIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr closureType ->
            -- Check this closure for stage arity violation
            let
                paramCount =
                    List.length closureInfo.params

                stageArity =
                    getStageArity closureType

                closureIssue =
                    if paramCount /= stageArity then
                        [ { context = context
                          , message =
                                "GOPT_001 violation: Closure expression has "
                                    ++ String.fromInt paramCount
                                    ++ " params but its type has stage arity "
                                    ++ String.fromInt stageArity
                          }
                        ]

                    else
                        []
            in
            closureIssue
                ++ List.concatMap (\( _, e, _ ) -> collectExprClosureIssues context e) closureInfo.captures
                ++ collectExprClosureIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            collectExprClosureIssues context fnExpr
                ++ List.concatMap (collectExprClosureIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprClosureIssues context e) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprClosureIssues context) exprs

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprClosureIssues context c ++ collectExprClosureIssues context t) branches
                ++ collectExprClosureIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefClosureIssues context def
                ++ collectExprClosureIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprClosureIssues context valueExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderClosureIssues context decider
                ++ List.concatMap (\( _, e ) -> collectExprClosureIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprClosureIssues context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprClosureIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprClosureIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprClosureIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprClosureIssues context) elementExprs

        _ ->
            []


{-| Collect closure issues from a MonoDef.
-}
collectDefClosureIssues : String -> Mono.MonoDef -> List Violation
collectDefClosureIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprClosureIssues context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprClosureIssues context expr


{-| Collect closure issues from a Decider tree.
-}
collectDeciderClosureIssues : String -> Mono.Decider Mono.MonoChoice -> List Violation
collectDeciderClosureIssues context decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectExprClosureIssues (context ++ " inline-leaf") expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectDeciderClosureIssues context success
                ++ collectDeciderClosureIssues context failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderClosureIssues context d) edges
                ++ collectDeciderClosureIssues context fallback
