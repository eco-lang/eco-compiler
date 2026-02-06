module TestLogic.Generate.CodeGen.CaseNotTerminator exposing (expectCaseNotTerminator, checkCaseNotTerminator)

{-| Test logic for CGEN\_045: eco.case is NOT a block terminator.

eco.case is a value-producing expression, not a control-flow terminator.
It must appear in block.body, never as block.terminator.

@docs expectCaseNotTerminator, checkCaseNotTerminator

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import TestLogic.TestPipeline exposing (runToMlir)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , violationsToExpectation
        , walkAllOps
        )


{-| Verify that eco.case is never used as a block terminator.
-}
expectCaseNotTerminator : Src.Module -> Expectation
expectCaseNotTerminator srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseNotTerminator mlirModule)


{-| Check that eco.case never appears as a block terminator.

CGEN\_045: eco.case is a value-producing op and must not be a terminator.

-}
checkCaseNotTerminator : MlirModule -> List Violation
checkCaseNotTerminator mlirModule =
    let
        allBlocks =
            walkAllBlocks mlirModule
    in
    List.filterMap checkBlockTerminator allBlocks


{-| Check a single block's terminator.
-}
checkBlockTerminator : MlirBlock -> Maybe Violation
checkBlockTerminator block =
    if block.terminator.name == "eco.case" then
        Just
            { opId = block.terminator.id
            , opName = "eco.case"
            , message =
                "eco.case found as block terminator but it is a value-producing op, not a terminator. "
                    ++ "eco.case must appear in block.body and produce SSA values."
            }

    else
        Nothing


{-| Walk all blocks in a module.
-}
walkAllBlocks : MlirModule -> List MlirBlock
walkAllBlocks mod =
    let
        allOps =
            walkAllOps mod
    in
    List.concatMap walkBlocksInOp allOps


walkBlocksInOp : MlirOp -> List MlirBlock
walkBlocksInOp op =
    List.concatMap walkBlocksInRegion op.regions


walkBlocksInRegion : MlirRegion -> List MlirBlock
walkBlocksInRegion (MlirRegion { entry, blocks }) =
    entry :: OrderedDict.values blocks
