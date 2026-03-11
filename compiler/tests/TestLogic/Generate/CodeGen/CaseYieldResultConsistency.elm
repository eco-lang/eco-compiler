module TestLogic.Generate.CodeGen.CaseYieldResultConsistency exposing (expectCaseYieldResultConsistency)

{-| Test logic for CGEN\_010: eco.case Yield-Result Type Consistency invariant.

eco.case has explicit MLIR result types; every alternative's eco.yield must
produce operands whose types match those result types (count and types).

Covers both single-result eco.case and multi-result eco.case (from TailRec).

@docs expectCaseYieldResultConsistency

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType)
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsNamed
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify CGEN\_010: eco.yield operand types match eco.case result types.
-}
expectCaseYieldResultConsistency : Src.Module -> Expectation
expectCaseYieldResultConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseYieldResultConsistency mlirModule)


checkCaseYieldResultConsistency : MlirModule -> List Violation
checkCaseYieldResultConsistency mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule
    in
    List.concatMap checkCaseOp caseOps


checkCaseOp : MlirOp -> List Violation
checkCaseOp caseOp =
    let
        expectedResultTypes =
            extractResultTypes caseOp
    in
    List.indexedMap (checkRegionYieldTypes caseOp.id expectedResultTypes) caseOp.regions
        |> List.concat


checkRegionYieldTypes : String -> List MlirType -> Int -> MlirRegion -> List Violation
checkRegionYieldTypes parentId expectedTypes branchIndex (MlirRegion { entry, blocks }) =
    let
        allBlocksList =
            entry :: OrderedDict.values blocks

        yieldOps =
            List.concatMap findYieldInBlock allBlocksList
    in
    List.concatMap (checkYieldAgainstExpected parentId expectedTypes branchIndex) yieldOps


findYieldInBlock : MlirBlock -> List MlirOp
findYieldInBlock block =
    if block.terminator.name == "eco.yield" then
        [ block.terminator ]

    else
        []


checkYieldAgainstExpected : String -> List MlirType -> Int -> MlirOp -> List Violation
checkYieldAgainstExpected parentId expectedTypes branchIndex yieldOp =
    case extractOperandTypes yieldOp of
        Nothing ->
            -- No _operand_types attr — skip (may be a bare yield)
            []

        Just yieldTypes ->
            let
                expectedCount =
                    List.length expectedTypes

                actualCount =
                    List.length yieldTypes
            in
            if expectedCount /= actualCount then
                [ { opId = parentId
                  , opName = "eco.case"
                  , message =
                        "Branch "
                            ++ String.fromInt branchIndex
                            ++ ": eco.yield has "
                            ++ String.fromInt actualCount
                            ++ " operands but eco.case expects "
                            ++ String.fromInt expectedCount
                            ++ " results"
                  }
                ]

            else
                List.filterMap identity
                    (List.indexedMap
                        (\i ( expected, actual ) ->
                            if expected == actual then
                                Nothing

                            else
                                Just
                                    { opId = parentId
                                    , opName = "eco.case"
                                    , message =
                                        "Branch "
                                            ++ String.fromInt branchIndex
                                            ++ " result "
                                            ++ String.fromInt i
                                            ++ ": eco.yield type "
                                            ++ Debug.toString actual
                                            ++ " != eco.case result type "
                                            ++ Debug.toString expected
                                    }
                        )
                        (List.map2 Tuple.pair expectedTypes yieldTypes)
                    )
