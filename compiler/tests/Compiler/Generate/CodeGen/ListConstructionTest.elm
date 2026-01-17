module Compiler.Generate.CodeGen.ListConstructionTest exposing (suite)

{-| Tests for CGEN_016: List Construction invariant.

List values must use `eco.construct.list` for cons cells and `eco.constant Nil`
for empty lists; never `eco.construct.custom`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , intExpr
        , listExpr
        , makeModule
        , strExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_016: List Construction"
        [ Test.test "Empty list uses eco.constant Nil, not eco.construct.custom" emptyListTest
        , Test.test "List literal uses eco.construct.list, not eco.construct.custom" listLiteralTest
        , Test.test "Cons expression uses eco.construct.list" consExpressionTest
        , Test.test "Chained cons uses eco.construct.list" chainedConsTest
        , Test.test "Nested list does not use eco.construct.custom for inner lists" nestedListTest
        ]



-- INVARIANT CHECKER


{-| Check that list construction uses proper operations.
-}
checkListConstruction : MlirModule -> List Violation
checkListConstruction mlirModule =
    let
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        listConstructorViolations =
            List.filterMap checkForListConstructorMisuse customOps
    in
    listConstructorViolations


{-| Check if an eco.construct.custom op is incorrectly used for list construction.
-}
checkForListConstructorMisuse : Mlir.Mlir.MlirOp -> Maybe Violation
checkForListConstructorMisuse op =
    let
        constructorName =
            getStringAttr "constructor" op
    in
    case constructorName of
        Just name ->
            if isListConstructorName name then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom used for list constructor '" ++ name ++ "', should use eco.construct.list or eco.constant Nil"
                    }

            else
                Nothing

        Nothing ->
            Nothing


isListConstructorName : String -> Bool
isListConstructorName name =
    List.member name [ "Cons", "Nil", "List.Cons", "List.Nil", "::" ]



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkListConstruction mlirModule)



-- TEST CASES


emptyListTest : () -> Expectation
emptyListTest _ =
    runInvariantTest (makeModule "testValue" (listExpr []))


listLiteralTest : () -> Expectation
listLiteralTest _ =
    runInvariantTest (makeModule "testValue" (listExpr [ intExpr 1, intExpr 2, intExpr 3 ]))


consExpressionTest : () -> Expectation
consExpressionTest _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 1, "::" ) ] (listExpr []))
    in
    runInvariantTest modul


chainedConsTest : () -> Expectation
chainedConsTest _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "::" )
                    , ( intExpr 2, "::" )
                    ]
                    (listExpr [])
                )
    in
    runInvariantTest modul


nestedListTest : () -> Expectation
nestedListTest _ =
    let
        modul =
            makeModule "testValue"
                (listExpr
                    [ listExpr [ intExpr 1, intExpr 2 ]
                    , listExpr [ intExpr 3, intExpr 4 ]
                    ]
                )
    in
    runInvariantTest modul
