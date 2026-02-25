module Compiler.GlobalOpt.CallInfo exposing (new, computeRemaining)

{-| Helper module for constructing CallInfo records.

This module provides:

  - `new` - Construct a CallInfo, computing derived fields from inputs


# API

@docs new, computeRemaining

-}

import Compiler.AST.Monomorphized as Mono



-- ============================================================================
-- CONSTRUCT CALLINFO
-- ============================================================================


{-| Construct a CallInfo, computing derived fields from the inputs.

Given callModel, stageArities, and argsApplied, this helper computes:

  - isSingleStageSaturated
  - initialRemaining
  - remainingStageArities

-}
new :
    { callModel : Mono.CallModel
    , stageArities : List Int
    , argsApplied : Int
    }
    -> Mono.CallInfo
new { callModel, stageArities, argsApplied } =
    let
        firstStage =
            List.head stageArities |> Maybe.withDefault 0

        isSingleStageSaturated =
            argsApplied == firstStage

        initialRemaining =
            firstStage

        remainingStageArities =
            computeRemaining stageArities argsApplied
    in
    { callModel = callModel
    , stageArities = stageArities
    , isSingleStageSaturated = isSingleStageSaturated
    , initialRemaining = initialRemaining
    , remainingStageArities = remainingStageArities
    , closureKind = Nothing
    , dispatchMode = Nothing
    , captureAbi = Nothing
    }


{-| Compute remaining stage arities after applying some arguments.
-}
computeRemaining : List Int -> Int -> List Int
computeRemaining stageArities argsApplied =
    case stageArities of
        [] ->
            []

        first :: rest ->
            if argsApplied >= first then
                computeRemaining rest (argsApplied - first)

            else
                (first - argsApplied) :: rest
