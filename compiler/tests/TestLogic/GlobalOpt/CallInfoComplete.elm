module TestLogic.GlobalOpt.CallInfoComplete exposing
    ( expectCallInfoComplete
    , checkNoPlaceholderCallInfo
    , checkStageAritiesNonEmpty
    , checkStageAritiesSumMatchesArity
    , checkPartialApplicationAritySemantics
    , checkSingleStageSaturated
    , checkFlattenedExternalCallInfo
    , Violation
    )

{-| Test logic for GOPT\_010-015: CallInfo invariants after GlobalOpt.

These invariants ensure that CallInfo metadata on every MonoCall is
correctly computed by GlobalOpt's annotateCallStaging phase.

@docs expectCallInfoComplete
@docs checkNoPlaceholderCallInfo
@docs checkStageAritiesNonEmpty
@docs checkStageAritiesSumMatchesArity
@docs checkPartialApplicationAritySemantics
@docs checkSingleStageSaturated
@docs checkFlattenedExternalCallInfo

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


{-| Run all CallInfo invariant checks (GOPT\_010-015).
-}
expectCallInfoComplete : Src.Module -> Expectation
expectCallInfoComplete srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                violations =
                    checkNoPlaceholderCallInfo optimizedMonoGraph
                        ++ checkStageAritiesNonEmpty optimizedMonoGraph
                        ++ checkStageAritiesSumMatchesArity optimizedMonoGraph
                        ++ checkPartialApplicationAritySemantics optimizedMonoGraph
                        ++ checkSingleStageSaturated optimizedMonoGraph
                        ++ checkFlattenedExternalCallInfo optimizedMonoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- GOPT_010: No placeholder CallInfo
-- ============================================================================


{-| GOPT\_010: After GlobalOpt, no MonoCall should have defaultCallInfo.
-}
checkNoPlaceholderCallInfo : Mono.MonoGraph -> List Violation
checkNoPlaceholderCallInfo graph =
    forAllCalls graph
        (\context _ _ callInfo ->
            if isDefaultCallInfo callInfo then
                [ { context = context
                  , message = "GOPT_010 violation: Call has defaultCallInfo (placeholder)"
                  }
                ]

            else
                []
        )


{-| Check if a CallInfo is the default placeholder.
-}
isDefaultCallInfo : Mono.CallInfo -> Bool
isDefaultCallInfo callInfo =
    List.isEmpty callInfo.stageArities && callInfo.initialRemaining == 0



-- ============================================================================
-- GOPT_011: stageArities non-empty for StageCurried
-- ============================================================================


{-| GOPT\_011: For StageCurried calls, stageArities must be non-empty with positive values.
-}
checkStageAritiesNonEmpty : Mono.MonoGraph -> List Violation
checkStageAritiesNonEmpty graph =
    forAllCalls graph
        (\context _ _ callInfo ->
            case callInfo.callModel of
                Mono.StageCurried ->
                    if List.isEmpty callInfo.stageArities then
                        [ { context = context
                          , message = "GOPT_011 violation: StageCurried call has empty stageArities"
                          }
                        ]

                    else if List.any (\n -> n <= 0) callInfo.stageArities then
                        [ { context = context
                          , message = "GOPT_011 violation: stageArities contains non-positive value"
                          }
                        ]

                    else
                        []

                Mono.FlattenedExternal ->
                    []
        )



-- ============================================================================
-- GOPT_012: stageArities sum equals flattened arity
-- ============================================================================


{-| GOPT\_012: For StageCurried calls, sum(stageArities) == flattenedArity(calleeType).
-}
checkStageAritiesSumMatchesArity : Mono.MonoGraph -> List Violation
checkStageAritiesSumMatchesArity graph =
    forAllCalls graph
        (\context fnExpr _ callInfo ->
            case callInfo.callModel of
                Mono.StageCurried ->
                    let
                        stageSum =
                            List.sum callInfo.stageArities

                        fnType =
                            Mono.typeOf fnExpr

                        flattenedArity =
                            getFlattenedArity fnType
                    in
                    -- Only check if we have a function type
                    if flattenedArity > 0 && stageSum /= flattenedArity then
                        [ { context = context
                          , message =
                                "GOPT_012 violation: sum(stageArities)="
                                    ++ String.fromInt stageSum
                                    ++ " but flattenedArity="
                                    ++ String.fromInt flattenedArity
                          }
                        ]

                    else
                        []

                Mono.FlattenedExternal ->
                    []
        )



-- ============================================================================
-- GOPT_013: PAP remaining-arity semantics
-- ============================================================================


{-| GOPT\_013: For partial applications, initialRemaining == sum(remainingStageArities).
-}
checkPartialApplicationAritySemantics : Mono.MonoGraph -> List Violation
checkPartialApplicationAritySemantics graph =
    forAllCalls graph
        (\context _ _ callInfo ->
            let
                remainingSum =
                    List.sum callInfo.remainingStageArities
            in
            if callInfo.initialRemaining /= remainingSum then
                [ { context = context
                  , message =
                        "GOPT_013 violation: initialRemaining="
                            ++ String.fromInt callInfo.initialRemaining
                            ++ " but sum(remainingStageArities)="
                            ++ String.fromInt remainingSum
                  }
                ]

            else
                []
        )



-- ============================================================================
-- GOPT_014: isSingleStageSaturated semantics
-- ============================================================================


{-| GOPT\_014: isSingleStageSaturated is true iff argCount >= stageArities[0].
-}
checkSingleStageSaturated : Mono.MonoGraph -> List Violation
checkSingleStageSaturated graph =
    forAllCallsWithArgs graph
        (\context _ argExprs callInfo ->
            case callInfo.callModel of
                Mono.StageCurried ->
                    let
                        argCount =
                            List.length argExprs

                        firstStageArity =
                            List.head callInfo.stageArities |> Maybe.withDefault 0

                        expected =
                            argCount >= firstStageArity
                    in
                    if callInfo.isSingleStageSaturated /= expected then
                        [ { context = context
                          , message =
                                "GOPT_014 violation: isSingleStageSaturated="
                                    ++ boolToString callInfo.isSingleStageSaturated
                                    ++ " but expected "
                                    ++ boolToString expected
                                    ++ " (argCount="
                                    ++ String.fromInt argCount
                                    ++ ", firstStageArity="
                                    ++ String.fromInt firstStageArity
                                    ++ ")"
                          }
                        ]

                    else
                        []

                Mono.FlattenedExternal ->
                    []
        )



-- ============================================================================
-- GOPT_015: FlattenedExternal has no staged currying
-- ============================================================================


{-| GOPT\_015: For FlattenedExternal calls, stage fields must be empty/zero.
-}
checkFlattenedExternalCallInfo : Mono.MonoGraph -> List Violation
checkFlattenedExternalCallInfo graph =
    forAllCalls graph
        (\context _ _ callInfo ->
            case callInfo.callModel of
                Mono.FlattenedExternal ->
                    let
                        issues =
                            (if not (List.isEmpty callInfo.stageArities) then
                                [ "stageArities not empty" ]

                             else
                                []
                            )
                                ++ (if not (List.isEmpty callInfo.remainingStageArities) then
                                        [ "remainingStageArities not empty" ]

                                    else
                                        []
                                   )
                                ++ (if callInfo.initialRemaining /= 0 then
                                        [ "initialRemaining=" ++ String.fromInt callInfo.initialRemaining ]

                                    else
                                        []
                                   )
                    in
                    if List.isEmpty issues then
                        []

                    else
                        [ { context = context
                          , message = "GOPT_015 violation: " ++ String.join ", " issues
                          }
                        ]

                Mono.StageCurried ->
                    []
        )



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Iterate over all MonoCall expressions, applying a check function.
-}
forAllCalls :
    Mono.MonoGraph
    -> (String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List Violation)
    -> List Violation
forAllCalls (Mono.MonoGraph data) checkFn =
    Dict.foldl compare
        (\specId node acc ->
            let
                context =
                    "SpecId " ++ String.fromInt specId
            in
            acc ++ collectCallsFromNode context checkFn node
        )
        []
        data.nodes


{-| Iterate over all MonoCall expressions with access to arg expressions.
-}
forAllCallsWithArgs :
    Mono.MonoGraph
    -> (String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List Violation)
    -> List Violation
forAllCallsWithArgs graph checkFn =
    forAllCalls graph checkFn


{-| Collect calls from a MonoNode.
-}
collectCallsFromNode :
    String
    -> (String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List Violation)
    -> Mono.MonoNode
    -> List Violation
collectCallsFromNode context checkFn node =
    case node of
        Mono.MonoDefine expr _ ->
            collectCallsFromExpr context checkFn expr

        Mono.MonoTailFunc _ expr _ ->
            collectCallsFromExpr context checkFn expr

        Mono.MonoPortIncoming expr _ ->
            collectCallsFromExpr context checkFn expr

        Mono.MonoPortOutgoing expr _ ->
            collectCallsFromExpr context checkFn expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectCallsFromExpr context checkFn e) defs

        _ ->
            []


{-| Collect calls from a MonoExpr.
-}
collectCallsFromExpr :
    String
    -> (String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List Violation)
    -> Mono.MonoExpr
    -> List Violation
collectCallsFromExpr context checkFn expr =
    case expr of
        Mono.MonoCall _ fnExpr argExprs _ callInfo ->
            -- Check this call
            checkFn context fnExpr argExprs callInfo
                ++ collectCallsFromExpr context checkFn fnExpr
                ++ List.concatMap (collectCallsFromExpr context checkFn) argExprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectCallsFromExpr context checkFn e) closureInfo.captures
                ++ collectCallsFromExpr context checkFn bodyExpr

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectCallsFromExpr context checkFn e) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectCallsFromExpr context checkFn) exprs

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectCallsFromExpr context checkFn c ++ collectCallsFromExpr context checkFn t) branches
                ++ collectCallsFromExpr context checkFn elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectCallsFromDef context checkFn def
                ++ collectCallsFromExpr context checkFn bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectCallsFromExpr context checkFn valueExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectCallsFromDecider context checkFn decider
                ++ List.concatMap (\( _, e ) -> collectCallsFromExpr context checkFn e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectCallsFromExpr context checkFn e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectCallsFromExpr context checkFn recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectCallsFromExpr context checkFn recordExpr
                ++ List.concatMap (\( _, e ) -> collectCallsFromExpr context checkFn e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectCallsFromExpr context checkFn) elementExprs

        _ ->
            []


{-| Collect calls from a MonoDef.
-}
collectCallsFromDef :
    String
    -> (String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List Violation)
    -> Mono.MonoDef
    -> List Violation
collectCallsFromDef context checkFn def =
    case def of
        Mono.MonoDef _ expr ->
            collectCallsFromExpr context checkFn expr

        Mono.MonoTailDef _ _ expr ->
            collectCallsFromExpr context checkFn expr


{-| Collect calls from a Decider tree.
-}
collectCallsFromDecider :
    String
    -> (String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List Violation)
    -> Mono.Decider Mono.MonoChoice
    -> List Violation
collectCallsFromDecider context checkFn decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectCallsFromExpr (context ++ " inline-leaf") checkFn expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectCallsFromDecider context checkFn success
                ++ collectCallsFromDecider context checkFn failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectCallsFromDecider context checkFn d) edges
                ++ collectCallsFromDecider context checkFn fallback


{-| Get the flattened arity of a function type.
-}
getFlattenedArity : Mono.MonoType -> Int
getFlattenedArity monoType =
    case monoType of
        Mono.MFunction params result ->
            List.length params + getFlattenedArity result

        _ ->
            0


{-| Convert Bool to String.
-}
boolToString : Bool -> String
boolToString b =
    if b then
        "True"

    else
        "False"
