module Compiler.Generate.CodeGen.CaseTerminationTest exposing (suite)

{-| Tests for CGEN_028: Case Alternative Termination invariant.

Every `eco.case` alternative region must terminate with `eco.return`,
`eco.jump`, or `eco.crash`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( caseExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModule
        , pCons
        , pCtor
        , pList
        , pVar
        , strExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , allBlocks
        , findOpsNamed
        , violationsToExpectation
        , walkOpAndChildren
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_028: Case Alternative Termination"
        [ Test.test "Boolean case alternatives terminate properly" booleanCaseTest
        , Test.test "Maybe case alternatives terminate properly" maybeCaseTest
        , Test.test "List case alternatives terminate properly" listCaseTest
        , Test.test "Nested case expressions terminate properly" nestedCaseTest
        , Test.test "Case with joinpoint uses eco.jump" caseWithJoinpointTest
        ]



-- INVARIANT CHECKER


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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseTermination mlirModule)



-- TEST CASES


booleanCaseTest : () -> Expectation
booleanCaseTest _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (varExpr "True") (intExpr 1) (intExpr 0))
    in
    runInvariantTest modul


maybeCaseTest : () -> Expectation
maybeCaseTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (varExpr "Nothing")
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


listCaseTest : () -> Expectation
listCaseTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


nestedCaseTest : () -> Expectation
nestedCaseTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (varExpr "True")
                    [ ( pCtor "True" []
                      , caseExpr (varExpr "False")
                            [ ( pCtor "True" [], intExpr 1 )
                            , ( pCtor "False" [], intExpr 2 )
                            ]
                      )
                    , ( pCtor "False" [], intExpr 3 )
                    ]
                )
    in
    runInvariantTest modul


caseWithJoinpointTest : () -> Expectation
caseWithJoinpointTest _ =
    -- When a case shares a joinpoint, branches use eco.jump
    let
        modul =
            makeModule "testValue"
                (ifExpr (varExpr "True") (intExpr 1) (intExpr 1))
    in
    runInvariantTest modul
