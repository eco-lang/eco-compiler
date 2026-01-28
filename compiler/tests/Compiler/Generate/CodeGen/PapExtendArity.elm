module Compiler.Generate.CodeGen.PapExtendArity exposing
    ( expectPapExtendArity
    , checkPapExtendArity
    )

{-| Test logic for CGEN_052: PapExtend remaining\_arity calculation invariant.

`eco.papExtend` remaining\_arity must equal the source PAP's remaining arity
(before this application), satisfying:

  - For `eco.papCreate`: remaining = arity - num\_captured
  - For chained `eco.papExtend`: remaining comes from source PAP's remaining
  - `remaining_arity >= num_new_args` (no over-application)

This test tracks PAP remaining arities from `eco.papCreate` ops and verifies that
each `eco.papExtend` uses the correct remaining\_arity matching its source PAP.

@docs expectPapExtendArity, checkPapExtendArity

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        , walkAllOps
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)


{-| Verify that papExtend remaining\_arity equals the source PAP's remaining arity.
-}
expectPapExtendArity : Src.Module -> Expectation
expectPapExtendArity srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapExtendArity mlirModule)


{-| Check papExtend remaining\_arity calculation invariants.

This builds a map of SSA value names to their PAP arities from eco.papCreate ops,
then verifies each eco.papExtend uses the correct remaining\_arity.

-}
checkPapExtendArity : MlirModule -> List Violation
checkPapExtendArity mlirModule =
    let
        -- Build a map from SSA value names to their PAP arities
        papArityMap =
            buildPapArityMap mlirModule

        -- Find all papExtend ops
        papExtendOps =
            findOpsNamed "eco.papExtend" mlirModule

        -- Check each papExtend
        violations =
            List.filterMap (checkPapExtendOp papArityMap) papExtendOps
    in
    violations


{-| Build a map from SSA value names to their PAP remaining arities.

This collects remaining arities from:

1.  eco.papCreate - remaining = arity - num\_captured (per dialect semantics)
2.  eco.papExtend - remaining = remaining\_arity - num\_new\_args

The map tracks how many arguments are still expected for each PAP value.

-}
buildPapArityMap : MlirModule -> Dict String Int
buildPapArityMap mlirModule =
    let
        allOps =
            walkAllOps mlirModule

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
    List.foldl processOp Dict.empty allOps


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
