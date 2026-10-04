module TestLogic.Generate.CodeGen.CaseYieldResultConsistency exposing (expectCaseYieldResultConsistency)

{-| Checks that the code generator makes each `eco.case` alternative yield
values of the types the `eco.case` declares for its results.

An `eco.case` is an MLIR operation that runs one of several alternatives, each a
region of its own, and declares a list of result types. An alternative supplies
the values of the results by ending in an `eco.yield`. The rule checked here is
that each such `eco.yield` records as many operand types as the `eco.case` has
results, and that the type at each position is the result type at that
position. An `eco.case` may have one result or several, and both are checked
the same way.

The types of an `eco.yield` are read from its `_operand_types` attribute, the
list of operand types the code generator records on the op, not from where its
operands were defined. An `eco.yield` without that attribute is not checked. Only
an `eco.yield` that ends a block of the alternative's own region is looked at;
whether every block ends with one is a separate rule, checked by
`TestLogic.Generate.CodeGen.CaseTermination`.

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


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when, for every `eco.case` at any
depth, each `eco.yield` ending a block of one of its alternatives records as
many operand types as the case has results, each equal to the result type at
the same position.

An `eco.yield` without an `_operand_types` attribute is not checked. The
expectation fails with `Compilation failed:` and the pipeline's error when
compilation fails before MLIR is generated. Otherwise each mismatch is a
violation, reported as `TestLogic.Generate.CodeGen.Invariants` describes for
`violationsToExpectation`, so a failure shows only the first one.

-}
expectCaseYieldResultConsistency : Src.Module -> Expectation
expectCaseYieldResultConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseYieldResultConsistency mlirModule)


{-| Returns the violations found in every `eco.case` in `mlirModule`, at any
depth.
-}
checkCaseYieldResultConsistency : MlirModule -> List Violation
checkCaseYieldResultConsistency mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule
    in
    List.concatMap checkCaseOp caseOps


{-| Returns the violations found in `caseOp`'s alternatives, checking each
`eco.yield` that ends one of their blocks against `caseOp`'s result types. A
region's position in `caseOp`'s regions is the branch number its violations
give.
-}
checkCaseOp : MlirOp -> List Violation
checkCaseOp caseOp =
    let
        expectedResultTypes =
            extractResultTypes caseOp
    in
    List.indexedMap (checkRegionYieldTypes caseOp.id expectedResultTypes) caseOp.regions
        |> List.concat


{-| Returns the violations of each `eco.yield` that ends a block of one
alternative region, the entry block and then the further blocks in order.
`parentId` is the id of the `eco.case`, `expectedTypes` its result types and
`branchIndex` the region's position in it.
-}
checkRegionYieldTypes : String -> List MlirType -> Int -> MlirRegion -> List Violation
checkRegionYieldTypes parentId expectedTypes branchIndex (MlirRegion { entry, blocks }) =
    let
        allBlocksList =
            entry :: OrderedDict.values blocks

        yieldOps =
            List.concatMap findYieldInBlock allBlocksList
    in
    List.concatMap (checkYieldAgainstExpected parentId expectedTypes branchIndex) yieldOps


{-| Returns the block's terminator in a list of one when it is an `eco.yield`,
and an empty list otherwise. An `eco.yield` in the block's body is not
returned.
-}
findYieldInBlock : MlirBlock -> List MlirOp
findYieldInBlock block =
    if block.terminator.name == "eco.yield" then
        [ block.terminator ]

    else
        []


{-| Returns the violations of one `eco.yield` against `expectedTypes`, the
result types of the `eco.case` whose id is `parentId`.

When the yield records a different number of operand types from the number of
expected types, the result is one violation giving both counts, and no type is
compared. When the counts agree, each position whose types differ gives one
violation. A yield with no `_operand_types` attribute gives none.

-}
checkYieldAgainstExpected : String -> List MlirType -> Int -> MlirOp -> List Violation
checkYieldAgainstExpected parentId expectedTypes branchIndex yieldOp =
    case extractOperandTypes yieldOp of
        Nothing ->
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
