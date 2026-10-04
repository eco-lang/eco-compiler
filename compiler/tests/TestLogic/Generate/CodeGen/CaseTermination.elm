module TestLogic.Generate.CodeGen.CaseTermination exposing (expectCaseTermination)

{-| Checks that the code generator ends every block of an `eco.case`
alternative with `eco.yield`, and with no other terminator.

An `eco.case` is an MLIR operation that runs one of several alternatives, each
a region of its own. As `Compiler.Generate.MLIR.Ops` describes, it is not a
terminator but an operation with results, and an alternative supplies the values
of those results by ending in an `eco.yield`. Under the rule checked here,
`eco.yield` is the only terminator allowed at the end of any block in an
alternative; `eco.return`, `eco.jump`, `eco.crash` and every other terminator
are reported.

`expectCaseTermination` compiles a program to MLIR, finds every `eco.case` at
any depth, and looks at the terminator of each block in each of its regions.
Only the blocks of the alternative's own region are looked at here; an
`eco.case` nested inside an alternative is found and checked on its own.

@docs expectCaseTermination

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when every block of every `eco.case`
alternative ends with `eco.yield`.

It fails with `Compilation failed:` and the pipeline's error when compilation
fails before MLIR is generated. Otherwise each block that ends with another
terminator is a violation, reported as `TestLogic.Generate.CodeGen.Invariants`
describes for `violationsToExpectation`, so a failure shows only the first one.

-}
expectCaseTermination : Src.Module -> Expectation
expectCaseTermination srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseTermination mlirModule)


{-| The names of the terminators allowed at the end of a block in an
`eco.case` alternative: `eco.yield` alone.
-}
validTerminators : List String
validTerminators =
    [ "eco.yield" ]


{-| Returns a violation for each block, in each region of each `eco.case` in
`mlirModule`, that ends with a terminator other than `eco.yield`.
-}
checkCaseTermination : MlirModule -> List Violation
checkCaseTermination mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule
    in
    List.concatMap checkCaseOp caseOps


{-| Returns a violation for each block of each region of `caseOp` that ends
with a terminator other than `eco.yield`. A region's position in `caseOp`'s
regions is the branch number its violations give.
-}
checkCaseOp : MlirOp -> List Violation
checkCaseOp caseOp =
    List.indexedMap (checkRegionTermination caseOp.id) caseOp.regions
        |> List.concat


{-| Returns a violation for each block of one alternative region that ends with
a terminator other than `eco.yield`, the entry block's violation first.

`parentId` is the id of the `eco.case` and `branchIndex` the region's position
in it. The entry block is named `entry` in a message, and each further block
`block_<n>`, where `n` is its position among the region's further blocks, not
its label.

-}
checkRegionTermination : String -> Int -> MlirRegion -> List Violation
checkRegionTermination parentId branchIndex (MlirRegion { entry, blocks }) =
    let
        entryViolation =
            checkBlockTermination parentId branchIndex "entry" entry

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


{-| Returns a violation, attributed to the `eco.case` whose id is `parentId`,
when `block` ends with a terminator other than `eco.yield`, or `Nothing` when it
ends with `eco.yield`. `branchIndex` and `blockName` say where the block is in
the message.
-}
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
                    ++ "', expected eco.yield"
            }
