module TestLogic.Generate.CodeGen.BlockTerminator exposing (expectBlockTerminator)

{-| Every block of generated MLIR is expected to end in a terminator, an op
such as `eco.return`, `eco.jump` or `eco.yield` that ends the block by passing
control elsewhere. Nothing in `Mlir.Mlir` enforces this: every `MlirBlock` has
a `terminator` field, but any op can be put there. This module compiles a
program to MLIR and checks the terminator of every block it can reach.

What counts as a terminator is decided by `isValidTerminator` in
`TestLogic.Generate.CodeGen.Invariants`, which compares the op's name with a
fixed list. Only the name is compared, so the check says nothing about where a
terminator may appear: `eco.yield` passes at the end of any block. `eco.case` is
not on the list, because it produces a value rather than ending a block.

Every op in the module is visited, at any depth, and for each of its regions
every block is checked, entry block first. Only a block's `terminator` field is
examined; an op in the block's body is not, even one flagged as a terminator. A
block that fails is reported as a violation of the op that owns its region, with
a message naming the region by its position among that op's regions and the
block as the entry block or by its position in the region.

@docs expectBlockTerminator

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , allBlocks
        , isValidTerminator
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when every block ends in a
terminator that `isValidTerminator` accepts.

When compilation fails, the expectation fails with `Compilation failed:`
followed by the pipeline's message. Otherwise, when there are violations, it
fails with the first one found, as `violationsToExpectation` reports it.

-}
expectBlockTerminator : Src.Module -> Expectation
expectBlockTerminator srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkBlockTerminators mlirModule)


{-| Returns a violation for each block, in each region of each op in the
module at any depth, whose terminator `isValidTerminator` does not accept.
-}
checkBlockTerminators : MlirModule -> List Violation
checkBlockTerminators mlirModule =
    let
        allOps =
            walkAllOps mlirModule
    in
    List.concatMap checkOpRegions allOps


{-| Returns the violations for the blocks in the regions of `op`, with the
regions numbered from 0 in the order `op` holds them.

Blocks belonging to ops nested inside those blocks are not included here;
`checkBlockTerminators` reaches them by visiting those ops in turn.

-}
checkOpRegions : MlirOp -> List Violation
checkOpRegions op =
    List.indexedMap (checkRegion op) op.regions
        |> List.concat


{-| Returns the violations for the blocks of `region`, which is region number
`regionIdx` of `parentOp`. The entry block is numbered 0 and the labelled blocks
follow in the order the region holds them.
-}
checkRegion : MlirOp -> Int -> MlirRegion -> List Violation
checkRegion parentOp regionIdx region =
    let
        blocks =
            allBlocks region
    in
    List.indexedMap (checkBlock parentOp regionIdx) blocks
        |> List.concat


{-| Returns one violation, reported against `parentOp`, when the terminator of
`block` is not accepted by `isValidTerminator`, and none otherwise.

The message names the region by `regionIdx` and the block as `entry block` when
`blockIdx` is 0, or as `block` followed by `blockIdx`, its position in the
region rather than its label. The branch for a terminator with an empty name is
never taken, because an empty name is not on the accepted list and is caught by
the first branch.

-}
checkBlock : MlirOp -> Int -> Int -> MlirBlock -> List Violation
checkBlock parentOp regionIdx blockIdx block =
    let
        terminator =
            block.terminator

        blockDesc =
            if blockIdx == 0 then
                "entry block"

            else
                "block " ++ String.fromInt blockIdx
    in
    if not (isValidTerminator terminator) then
        [ { opId = parentOp.id
          , opName = parentOp.name
          , message =
                "region "
                    ++ String.fromInt regionIdx
                    ++ " "
                    ++ blockDesc
                    ++ " terminator '"
                    ++ terminator.name
                    ++ "' is not a valid terminator"
          }
        ]

    else if terminator.name == "" then
        [ { opId = parentOp.id
          , opName = parentOp.name
          , message =
                "region "
                    ++ String.fromInt regionIdx
                    ++ " "
                    ++ blockDesc
                    ++ " has empty/missing terminator"
          }
        ]

    else
        []
