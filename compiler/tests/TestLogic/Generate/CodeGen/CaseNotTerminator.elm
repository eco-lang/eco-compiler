module TestLogic.Generate.CodeGen.CaseNotTerminator exposing (expectCaseNotTerminator)

{-| Checks that the code generator never puts an `eco.case` op in the
terminator slot of a block, the place for the op that ends the block.

An `eco.case` chooses one of its regions, the alternatives, by the value of its
scrutinee, and its SSA results are the values that alternative yields. It is
an ordinary op of a block's body, as `Compiler.Generate.MLIR.Ops` describes.
An `MlirBlock` keeps its body ops and its terminator in separate fields, so
nothing in the types stops an `eco.case` being placed in the wrong one.

`expectCaseNotTerminator` compiles the program it is given to MLIR with
`TestLogic.TestPipeline.runToMlir`, and fails when compilation fails. It then
looks at every block of every region of every op in the module, at any depth,
and fails when a block's terminator is named `eco.case`. When several blocks
fail, only the first is reported, as `violationsToExpectation` describes.

Among what is not tested: what ends each alternative of an `eco.case`, and an
`eco.case` in a block's body that is flagged as a terminator.

@docs expectCaseNotTerminator

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
no block in the result has an `eco.case` as its terminator. It fails with the
compiler's message if compilation fails.
-}
expectCaseNotTerminator : Src.Module -> Expectation
expectCaseNotTerminator srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseNotTerminator mlirModule)


{-| Returns a violation for each block in the module whose terminator is an
`eco.case`.
-}
checkCaseNotTerminator : MlirModule -> List Violation
checkCaseNotTerminator mlirModule =
    let
        allBlocks =
            walkAllBlocks mlirModule
    in
    List.filterMap checkBlockTerminator allBlocks


{-| Returns a violation when the block's terminator is an `eco.case`, and
`Nothing` otherwise.
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


{-| Returns every block in the module: the blocks of each region of every op,
at any depth.
-}
walkAllBlocks : MlirModule -> List MlirBlock
walkAllBlocks mod =
    let
        allOps =
            walkAllOps mod
    in
    List.concatMap walkBlocksInOp allOps


{-| Returns the blocks of each of the op's regions, without those of the
regions nested inside them.
-}
walkBlocksInOp : MlirOp -> List MlirBlock
walkBlocksInOp op =
    List.concatMap walkBlocksInRegion op.regions


{-| Returns the region's blocks: the entry block, then the labelled blocks in
the order the region holds them.
-}
walkBlocksInRegion : MlirRegion -> List MlirBlock
walkBlocksInRegion (MlirRegion { entry, blocks }) =
    entry :: OrderedDict.values blocks
