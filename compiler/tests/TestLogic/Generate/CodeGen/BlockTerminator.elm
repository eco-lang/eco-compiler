module TestLogic.Generate.CodeGen.BlockTerminator exposing (expectBlockTerminator, checkBlockTerminators)

{-| Test logic for CGEN\_042: Block Terminator Presence invariant.

Every block in every region emitted by MLIR codegen must end with a
terminator operation (e.g. `eco.return`, `eco.jump`, `eco.yield`, `scf.yield`).

Note: `eco.case` is NOT a terminator - it is a value-producing expression.
`eco.yield` is used to terminate eco.case alternative regions.

@docs expectBlockTerminator, checkBlockTerminators

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import TestLogic.TestPipeline exposing (runToMlir)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , allBlocks
        , isValidTerminator
        , violationsToExpectation
        , walkAllOps
        )


{-| Verify that block terminator invariants hold for a source module.
-}
expectBlockTerminator : Src.Module -> Expectation
expectBlockTerminator srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkBlockTerminators mlirModule)


{-| Check block terminator presence invariants.
-}
checkBlockTerminators : MlirModule -> List Violation
checkBlockTerminators mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        violations =
            List.concatMap checkOpRegions allOps
    in
    violations


checkOpRegions : MlirOp -> List Violation
checkOpRegions op =
    List.indexedMap (checkRegion op) op.regions
        |> List.concat


checkRegion : MlirOp -> Int -> MlirRegion -> List Violation
checkRegion parentOp regionIdx region =
    let
        blocks =
            allBlocks region
    in
    List.indexedMap (checkBlock parentOp regionIdx) blocks
        |> List.concat


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
