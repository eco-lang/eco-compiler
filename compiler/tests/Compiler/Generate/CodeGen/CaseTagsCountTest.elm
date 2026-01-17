module Compiler.Generate.CodeGen.CaseTagsCountTest exposing (suite)

{-| Tests for CGEN_029: Case Tags Count invariant.

The `eco.case` `tags` array length must equal the number of alternative regions.

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
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getArrayAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_029: Case Tags Count"
        [ Test.test "Boolean case has 2 tags and 2 regions" booleanCaseTagsTest
        , Test.test "Maybe case has 2 tags and 2 regions" maybeCaseTagsTest
        , Test.test "List case has 2 tags and 2 regions" listCaseTagsTest
        , Test.test "eco.case has tags attribute" hasTagsAttrTest
        ]



-- INVARIANT CHECKER


{-| Check case tags count invariants.
-}
checkCaseTagsCount : MlirModule -> List Violation
checkCaseTagsCount mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule

        violations =
            List.filterMap checkCaseTagsMatch caseOps
    in
    violations


checkCaseTagsMatch : MlirOp -> Maybe Violation
checkCaseTagsMatch op =
    let
        maybeTagsAttr =
            getArrayAttr "tags" op

        regionCount =
            List.length op.regions
    in
    case maybeTagsAttr of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.case missing tags attribute"
                }

        Just tags ->
            let
                tagCount =
                    List.length tags
            in
            if tagCount /= regionCount then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.case tags count ("
                            ++ String.fromInt tagCount
                            ++ ") != region count ("
                            ++ String.fromInt regionCount
                            ++ ")"
                    }

            else
                Nothing



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseTagsCount mlirModule)



-- TEST CASES


booleanCaseTagsTest : () -> Expectation
booleanCaseTagsTest _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (varExpr "True") (intExpr 1) (intExpr 0))
    in
    runInvariantTest modul


maybeCaseTagsTest : () -> Expectation
maybeCaseTagsTest _ =
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


listCaseTagsTest : () -> Expectation
listCaseTagsTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


hasTagsAttrTest : () -> Expectation
hasTagsAttrTest _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (varExpr "True")
                    [ ( pCtor "True" [], intExpr 1 )
                    , ( pCtor "False" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul
