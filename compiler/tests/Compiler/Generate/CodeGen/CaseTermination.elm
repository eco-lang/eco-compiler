module Compiler.Generate.CodeGen.CaseTermination exposing
    ( expectCaseTermination
    , checkCaseTermination
    )

{-| Test logic for CGEN_028: Case Alternative Termination invariant.

Every `eco.case` alternative region must terminate with `eco.return`,
`eco.jump`, or `eco.crash`.

@docs expectCaseTermination, checkCaseTermination

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict


{-| Verify that case termination invariants hold for a source module.
-}
expectCaseTermination : Src.Module -> Expectation
expectCaseTermination srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseTermination mlirModule)


validTerminators : List String
validTerminators =
    [ "eco.return", "eco.jump", "eco.crash" ]


{-| Check case termination invariants.
-}
checkCaseTermination : MlirModule -> List Violation
checkCaseTermination mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule

        violations =
            List.concatMap checkCaseOp caseOps
    in
    violations


checkCaseOp : MlirOp -> List Violation
checkCaseOp caseOp =
    List.indexedMap (checkRegionTermination caseOp.id) caseOp.regions
        |> List.concat


checkRegionTermination : String -> Int -> MlirRegion -> List Violation
checkRegionTermination parentId branchIndex (MlirRegion { entry, blocks }) =
    let
        entryViolation =
            checkBlockTermination parentId branchIndex "entry" entry

        -- Use allBlocks but skip entry (it's already checked)
        blockViolations =
            OrderedDict.values blocks
                |> List.indexedMap
                    (\i block ->
                        checkBlockTermination parentId branchIndex ("block_" ++ String.fromInt i) block
                    )
                |> List.filterMap identity
    in
    case entryViolation of
        Just v ->
            v :: blockViolations

        Nothing ->
            blockViolations


checkBlockTermination : String -> Int -> String -> MlirBlock -> Maybe Violation
checkBlockTermination parentId branchIndex blockName block =
    if List.member block.terminator.name validTerminators then
        Nothing

    else
        Just
            { opId = parentId
            , opName = "eco.case"
            , message =
                "Branch "
                    ++ String.fromInt branchIndex
                    ++ " "
                    ++ blockName
                    ++ " terminates with '"
                    ++ block.terminator.name
                    ++ "', expected eco.return, eco.jump, or eco.crash"
            }
