module TestLogic.Generate.CodeGen.PapExtendArity exposing (expectPapExtendArity)

{-| Test logic for CGEN\_052: PapExtend remaining\_arity calculation invariant.

`eco.papExtend` remaining\_arity must equal the source PAP's remaining arity
(before this application), satisfying:

  - For `eco.papCreate`: remaining = arity - num\_captured
  - For chained `eco.papExtend`: remaining comes from source PAP's remaining
  - `remaining_arity >= num_new_args` (no over-application)

This test tracks PAP remaining arities from `eco.papCreate` ops and verifies that
each `eco.papExtend` uses the correct remaining\_arity matching its source PAP.

Note: SSA variable names are only unique within each function, not globally.
This test checks invariants per-function to avoid false positives from SSA
name collisions across different functions.

@docs expectPapExtendArity

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , getIntAttr
        , violationsToExpectation
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that papExtend remaining\_arity equals the source PAP's remaining arity.
-}
expectPapExtendArity : Src.Module -> Expectation
expectPapExtendArity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapExtendArity mlirModule)


{-| Check papExtend remaining\_arity calculation invariants.

This processes each function independently to avoid SSA name collisions.
For each function, it builds a map of SSA value names to their PAP arities
from eco.papCreate ops, then verifies each eco.papExtend uses the correct
remaining\_arity.

-}
checkPapExtendArity : MlirModule -> List Violation
checkPapExtendArity mlirModule =
    -- Process each top-level op (function) independently
    List.concatMap checkFunction mlirModule.body


{-| Check PAP arities within a single function.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        -- Get all ops within this function
        allOpsInFunc =
            walkOpAndChildren funcOp

        -- Build a map from SSA value names to their PAP arities for this function
        papArityMap =
            buildPapArityMapForOps allOpsInFunc

        -- Find all papExtend ops in this function
        papExtendOps =
            List.filter (\op -> op.name == "eco.papExtend") allOpsInFunc
    in
    -- Check each papExtend against the function-local arity map
    List.filterMap (checkPapExtendOp papArityMap) papExtendOps


{-| Build a map from SSA value names to their PAP remaining arities for a list of ops.

This collects remaining arities from:

1.  eco.papCreate - remaining = arity - num\_captured (per dialect semantics)
2.  eco.papExtend - remaining = remaining\_arity - num\_new\_args

The map tracks how many arguments are still expected for each PAP value.

-}
buildPapArityMapForOps : List MlirOp -> Dict String Int
buildPapArityMapForOps ops =
    let
        -- Process each op and add to map
        processOp : MlirOp -> Dict String Int -> Dict String Int
        processOp op map =
            if op.name == "eco.papCreate" then
                -- eco.papCreate: remaining = arity - num_captured
                case ( List.head op.results, getIntAttr "arity" op, getIntAttr "num_captured" op ) of
                    ( Just ( resultName, _ ), Just arity, Just numCaptured ) ->
                        let
                            remaining =
                                arity - numCaptured
                        in
                        Dict.insert resultName remaining map

                    _ ->
                        map

            else if op.name == "eco.papExtend" then
                -- eco.papExtend: result remaining = remaining_arity - numNewArgs
                case ( List.head op.results, getIntAttr "remaining_arity" op ) of
                    ( Just ( resultName, _ ), Just remainingArity ) ->
                        let
                            numNewArgs =
                                List.length op.operands - 1

                            resultRemaining =
                                remainingArity - numNewArgs
                        in
                        -- Only add if still a PAP (remaining > 0)
                        if resultRemaining > 0 then
                            Dict.insert resultName resultRemaining map

                        else
                            map

                    _ ->
                        map

            else
                map
    in
    List.foldl processOp Dict.empty ops


{-| Check a single papExtend op for remaining\_arity correctness.
-}
checkPapExtendOp : Dict String Int -> MlirOp -> Maybe Violation
checkPapExtendOp papArityMap op =
    let
        maybeRemainingArity =
            getIntAttr "remaining_arity" op

        -- First operand is the PAP being extended
        maybeSourcePap =
            List.head op.operands

        -- New args are all operands after the first
        numNewArgs =
            List.length op.operands - 1
    in
    case maybeRemainingArity of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.papExtend missing remaining_arity attribute"
                }

        Just remainingArity ->
            -- Check remaining_arity >= 0
            if remainingArity < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.papExtend remaining_arity="
                            ++ String.fromInt remainingArity
                            ++ " is negative"
                    }

            else
                -- Check the calculation: remaining_arity = source_arity - num_new_args
                case maybeSourcePap of
                    Nothing ->
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message = "eco.papExtend has no source PAP operand"
                            }

                    Just sourcePapName ->
                        case Dict.get sourcePapName papArityMap of
                            Nothing ->
                                -- Source PAP not found in our map - could be a function
                                -- reference or block argument. Skip this check.
                                -- The runtime will catch actual errors.
                                Nothing

                            Just sourceRemaining ->
                                -- remaining_arity attribute should equal source PAP's remaining arity
                                -- (this is the closure's remaining arity *before* this application)
                                if remainingArity /= sourceRemaining then
                                    Just
                                        { opId = op.id
                                        , opName = op.name
                                        , message =
                                            "eco.papExtend remaining_arity="
                                                ++ String.fromInt remainingArity
                                                ++ " but source PAP has remaining="
                                                ++ String.fromInt sourceRemaining
                                        }

                                else if remainingArity < numNewArgs then
                                    Just
                                        { opId = op.id
                                        , opName = op.name
                                        , message =
                                            "eco.papExtend over-applies: remaining_arity="
                                                ++ String.fromInt remainingArity
                                                ++ " but num_new_args="
                                                ++ String.fromInt numNewArgs
                                        }

                                else
                                    Nothing
