module Compiler.Type.PostSolve.PostSolveExprTests exposing (expectSuite)

{-| Test cases for PostSolve expression type resolution.

These tests exercise various expression types through the PostSolve phase
to improve coverage of Compiler.Type.PostSolve.postSolveExpr and related functions.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , UnionDef
        , accessExpr
        , accessorExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , ctorExpr
        , define
        , destruct
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , negateExpr
        , pAnything
        , pCtor
        , pInt
        , pRecord
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tVar
        , tuple3Expr
        , tupleExpr
        , unitExpr
        , updateExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("PostSolve expression types " ++ condStr)
        [ literalTypeTests expectFn condStr
        , structuralTypeTests expectFn condStr
        , lambdaTypeTests expectFn condStr
        , accessorTypeTests expectFn condStr
        , letBindingTypeTests expectFn condStr
        , controlFlowTypeTests expectFn condStr
        , recordUpdateTypeTests expectFn condStr
        , callTypeTests expectFn condStr
        , binopTypeTests expectFn condStr
        , negateTypeTests expectFn condStr
        ]



-- ============================================================================
-- LITERAL TYPE TESTS (6 tests)
-- ============================================================================


literalTypeTests : (Src.Module -> Expectation) -> String -> Test
literalTypeTests expectFn condStr =
    Test.describe ("Literal types " ++ condStr)
        [ Test.test ("String literal type " ++ condStr) (stringLiteralType expectFn)
        , Test.test ("Char literal type " ++ condStr) (charLiteralType expectFn)
        , Test.test ("Float literal type " ++ condStr) (floatLiteralType expectFn)
        , Test.test ("Unit literal type " ++ condStr) (unitLiteralType expectFn)
        , Test.test ("Int literal type " ++ condStr) (intLiteralType expectFn)
        , Test.test ("Bool literal type " ++ condStr) (boolLiteralType expectFn)
        ]


stringLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
stringLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "hello world")
    in
    expectFn modul


charLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
charLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "x")
    in
    expectFn modul


floatLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
floatLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 3.14159)
    in
    expectFn modul


unitLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
unitLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" unitExpr
    in
    expectFn modul


intLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 42)
    in
    expectFn modul


boolLiteralType : (Src.Module -> Expectation) -> (() -> Expectation)
boolLiteralType expectFn _ =
    let
        modul =
            makeModule "testValue" (boolExpr True)
    in
    expectFn modul



-- ============================================================================
-- STRUCTURAL TYPE TESTS (8 tests)
-- ============================================================================


structuralTypeTests : (Src.Module -> Expectation) -> String -> Test
structuralTypeTests expectFn condStr =
    Test.describe ("Structural types " ++ condStr)
        [ Test.test ("Empty list type " ++ condStr) (emptyListType expectFn)
        , Test.test ("Singleton list type " ++ condStr) (singletonListType expectFn)
        , Test.test ("Multiple element list type " ++ condStr) (multipleElementListType expectFn)
        , Test.test ("Tuple2 type " ++ condStr) (tuple2Type expectFn)
        , Test.test ("Tuple3 type " ++ condStr) (tuple3Type expectFn)
        , Test.test ("Simple record type " ++ condStr) (simpleRecordType expectFn)
        , Test.test ("Nested record type " ++ condStr) (nestedRecordType expectFn)
        , Test.test ("Multi-field record type " ++ condStr) (multiFieldRecordType expectFn)
        ]


emptyListType : (Src.Module -> Expectation) -> (() -> Expectation)
emptyListType expectFn _ =
    let
        -- testValue : List Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body = listExpr []
            }

        modul =
            makeModuleWithTypedDefs "Test" [ testValueDef ]
    in
    expectFn modul


singletonListType : (Src.Module -> Expectation) -> (() -> Expectation)
singletonListType expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 1 ])
    in
    expectFn modul


multipleElementListType : (Src.Module -> Expectation) -> (() -> Expectation)
multipleElementListType expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
    in
    expectFn modul


tuple2Type : (Src.Module -> Expectation) -> (() -> Expectation)
tuple2Type expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr 1) (strExpr "hello"))
    in
    expectFn modul


tuple3Type : (Src.Module -> Expectation) -> (() -> Expectation)
tuple3Type expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr 1) (strExpr "hello") (boolExpr True))
    in
    expectFn modul


simpleRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleRecordType expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [ ( "x", intExpr 10 ) ])
    in
    expectFn modul


nestedRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "outer"
                      , recordExpr
                            [ ( "inner", intExpr 42 )
                            ]
                      )
                    ]
                )
    in
    expectFn modul


multiFieldRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "a", intExpr 1 )
                    , ( "b", strExpr "two" )
                    , ( "c", boolExpr True )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- LAMBDA TYPE TESTS (6 tests)
-- ============================================================================


lambdaTypeTests : (Src.Module -> Expectation) -> String -> Test
lambdaTypeTests expectFn condStr =
    Test.describe ("Lambda types " ++ condStr)
        [ Test.test ("Simple lambda type " ++ condStr) (simpleLambdaType expectFn)
        , Test.test ("Multi-arg lambda type " ++ condStr) (multiArgLambdaType expectFn)
        , Test.test ("Lambda returning lambda type " ++ condStr) (lambdaReturningLambdaType expectFn)
        , Test.test ("Identity lambda type " ++ condStr) (identityLambdaType expectFn)
        , Test.test ("Lambda with record arg type " ++ condStr) (lambdaWithRecordArgType expectFn)
        , Test.test ("Lambda with tuple result type " ++ condStr) (lambdaWithTupleResultType expectFn)
        ]


simpleLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleLambdaType expectFn _ =
    let
        -- increment : Int -> Int
        incrementDef : TypedDef
        incrementDef =
            { name = "increment"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "increment") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ incrementDef, testValueDef ]
    in
    expectFn modul


multiArgLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
multiArgLambdaType expectFn _ =
    let
        -- add : Int -> Int -> Int
        addDef : TypedDef
        addDef =
            { name = "add"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "add") [ intExpr 3, intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ addDef, testValueDef ]
    in
    expectFn modul


lambdaReturningLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningLambdaType expectFn _ =
    let
        -- makeAdder : Int -> (Int -> Int)
        makeAdderDef : TypedDef
        makeAdderDef =
            { name = "makeAdder"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (callExpr (varExpr "makeAdder") [ intExpr 10 ]) [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ makeAdderDef, testValueDef ]
    in
    expectFn modul


identityLambdaType : (Src.Module -> Expectation) -> (() -> Expectation)
identityLambdaType expectFn _ =
    let
        -- identity : a -> a (monomorphized to Int -> Int)
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tVar "a")
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "identity") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ identityDef, testValueDef ]
    in
    expectFn modul


lambdaWithRecordArgType : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithRecordArgType expectFn _ =
    let
        -- getX : { x : Int } -> Int
        getXDef : TypedDef
        getXDef =
            { name = "getX"
            , args = [ pVar "r" ]
            , tipe = tLambda (tRecord [ ( "x", tType "Int" [] ) ]) (tType "Int" [])
            , body = accessExpr (varExpr "r") "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getX") [ recordExpr [ ( "x", intExpr 10 ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ getXDef, testValueDef ]
    in
    expectFn modul


lambdaWithTupleResultType : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithTupleResultType expectFn _ =
    let
        -- pair : Int -> ( Int, Int )
        pairDef : TypedDef
        pairDef =
            { name = "pair"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tTuple (tType "Int" []) (tType "Int" []))
            , body = tupleExpr (varExpr "x") (varExpr "x")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "pair") [ intExpr 7 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ pairDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- ACCESSOR TYPE TESTS (4 tests)
-- ============================================================================


accessorTypeTests : (Src.Module -> Expectation) -> String -> Test
accessorTypeTests expectFn condStr =
    Test.describe ("Accessor types " ++ condStr)
        [ Test.test ("Simple accessor type " ++ condStr) (simpleAccessorType expectFn)
        , Test.test ("Accessor on nested record type " ++ condStr) (accessorOnNestedRecordType expectFn)
        , Test.test ("Accessor function type " ++ condStr) (accessorFunctionType expectFn)
        , Test.test ("Multiple accessor chain type " ++ condStr) (multipleAccessorChainType expectFn)
        ]


simpleAccessorType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAccessorType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (accessExpr (recordExpr [ ( "name", strExpr "Alice" ) ]) "name")
    in
    expectFn modul


accessorOnNestedRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
accessorOnNestedRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (accessExpr
                    (accessExpr
                        (recordExpr
                            [ ( "person"
                              , recordExpr [ ( "age", intExpr 30 ) ]
                              )
                            ]
                        )
                        "person"
                    )
                    "age"
                )
    in
    expectFn modul


accessorFunctionType : (Src.Module -> Expectation) -> (() -> Expectation)
accessorFunctionType expectFn _ =
    let
        -- Uses .field accessor syntax as a function
        -- getField : { field : Int } -> Int
        getFieldDef : TypedDef
        getFieldDef =
            { name = "getField"
            , args = []
            , tipe = tLambda (tRecord [ ( "field", tType "Int" [] ) ]) (tType "Int" [])
            , body = accessorExpr "field"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getField") [ recordExpr [ ( "field", intExpr 99 ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ getFieldDef, testValueDef ]
    in
    expectFn modul


multipleAccessorChainType : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAccessorChainType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (accessExpr
                    (accessExpr
                        (accessExpr
                            (recordExpr
                                [ ( "level1"
                                  , recordExpr
                                        [ ( "level2"
                                          , recordExpr [ ( "value", intExpr 123 ) ]
                                          )
                                        ]
                                  )
                                ]
                            )
                            "level1"
                        )
                        "level2"
                    )
                    "value"
                )
    in
    expectFn modul



-- ============================================================================
-- LET BINDING TYPE TESTS (6 tests)
-- ============================================================================


letBindingTypeTests : (Src.Module -> Expectation) -> String -> Test
letBindingTypeTests expectFn condStr =
    Test.describe ("Let binding types " ++ condStr)
        [ Test.test ("Simple let type " ++ condStr) (simpleLetType expectFn)
        , Test.test ("Nested let type " ++ condStr) (nestedLetType expectFn)
        , Test.test ("Let with function type " ++ condStr) (letWithFunctionType expectFn)
        , Test.test ("Let destruct tuple type " ++ condStr) (letDestructTupleType expectFn)
        , Test.test ("Let destruct record type " ++ condStr) (letDestructRecordType expectFn)
        , Test.test ("Multiple let bindings type " ++ condStr) (multipleLetBindingsType expectFn)
        ]


simpleLetType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleLetType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "x" [] (intExpr 42) ]
                    (varExpr "x")
                )
    in
    expectFn modul


nestedLetType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLetType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "x" [] (intExpr 10) ]
                    (letExpr
                        [ define "y" [] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 5)) ]
                        (varExpr "y")
                    )
                )
    in
    expectFn modul


letWithFunctionType : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFunctionType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "double" [ pVar "n" ] (binopsExpr [ ( varExpr "n", "*" ) ] (intExpr 2)) ]
                    (callExpr (varExpr "double") [ intExpr 21 ])
                )
    in
    expectFn modul


letDestructTupleType : (Src.Module -> Expectation) -> (() -> Expectation)
letDestructTupleType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 1) (intExpr 2)) ]
                    (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                )
    in
    expectFn modul


letDestructRecordType : (Src.Module -> Expectation) -> (() -> Expectation)
letDestructRecordType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ destruct (pRecord [ "x", "y" ]) (recordExpr [ ( "x", intExpr 3 ), ( "y", intExpr 4 ) ]) ]
                    (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
                )
    in
    expectFn modul


multipleLetBindingsType : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLetBindingsType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "a" [] (intExpr 1)
                    , define "b" [] (intExpr 2)
                    , define "c" [] (intExpr 3)
                    ]
                    (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                )
    in
    expectFn modul



-- ============================================================================
-- CONTROL FLOW TYPE TESTS (6 tests)
-- ============================================================================


controlFlowTypeTests : (Src.Module -> Expectation) -> String -> Test
controlFlowTypeTests expectFn condStr =
    Test.describe ("Control flow types " ++ condStr)
        [ Test.test ("Simple if type " ++ condStr) (simpleIfType expectFn)
        , Test.test ("Nested if type " ++ condStr) (nestedIfType expectFn)
        , Test.test ("If with different result types " ++ condStr) (ifWithRecordResultType expectFn)
        , Test.test ("Simple case type " ++ condStr) (simpleCaseType expectFn)
        , Test.test ("Multi-branch case type " ++ condStr) (multiBranchCaseType expectFn)
        , Test.test ("Case with nested patterns type " ++ condStr) (caseWithNestedPatternsType expectFn)
        ]


simpleIfType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleIfType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True) (intExpr 1) (intExpr 0))
    in
    expectFn modul


nestedIfType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedIfType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (ifExpr (boolExpr False) (intExpr 1) (intExpr 2))
                    (intExpr 3)
                )
    in
    expectFn modul


ifWithRecordResultType : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithRecordResultType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (recordExpr [ ( "value", intExpr 1 ) ])
                    (recordExpr [ ( "value", intExpr 2 ) ])
                )
    in
    expectFn modul


simpleCaseType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCaseType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 1)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul


multiBranchCaseType : (Src.Module -> Expectation) -> (() -> Expectation)
multiBranchCaseType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 5)
                    [ ( pInt 0, intExpr 100 )
                    , ( pInt 1, intExpr 101 )
                    , ( pInt 2, intExpr 102 )
                    , ( pInt 3, intExpr 103 )
                    , ( pInt 4, intExpr 104 )
                    , ( pAnything, intExpr 999 )
                    ]
                )
    in
    expectFn modul


caseWithNestedPatternsType : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithNestedPatternsType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tupleExpr (intExpr 1) (intExpr 2))
                    [ ( pTuple (pInt 0) (pVar "y"), varExpr "y" )
                    , ( pTuple (pVar "x") (pInt 0), varExpr "x" )
                    , ( pTuple (pVar "x") (pVar "y"), binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y") )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- RECORD UPDATE TYPE TESTS (4 tests)
-- ============================================================================


recordUpdateTypeTests : (Src.Module -> Expectation) -> String -> Test
recordUpdateTypeTests expectFn condStr =
    Test.describe ("Record update types " ++ condStr)
        [ Test.test ("Simple record update type " ++ condStr) (simpleRecordUpdateType expectFn)
        , Test.test ("Multi-field record update type " ++ condStr) (multiFieldRecordUpdateType expectFn)
        , Test.test ("Record update with expression type " ++ condStr) (recordUpdateWithExpressionType expectFn)
        , Test.test ("Nested record update type " ++ condStr) (nestedRecordUpdateType expectFn)
        ]


simpleRecordUpdateType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleRecordUpdateType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r" [] (recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]) ]
                    (updateExpr (varExpr "r") [ ( "x", intExpr 10 ) ])
                )
    in
    expectFn modul


multiFieldRecordUpdateType : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordUpdateType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r" [] (recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ) ]) ]
                    (updateExpr (varExpr "r") [ ( "a", intExpr 100 ), ( "c", intExpr 300 ) ])
                )
    in
    expectFn modul


recordUpdateWithExpressionType : (Src.Module -> Expectation) -> (() -> Expectation)
recordUpdateWithExpressionType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r" [] (recordExpr [ ( "count", intExpr 5 ) ]) ]
                    (updateExpr (varExpr "r")
                        [ ( "count", binopsExpr [ ( accessExpr (varExpr "r") "count", "+" ) ] (intExpr 1) ) ]
                    )
                )
    in
    expectFn modul


nestedRecordUpdateType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordUpdateType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "outer" []
                        (recordExpr
                            [ ( "inner", recordExpr [ ( "value", intExpr 1 ) ] )
                            ]
                        )
                    ]
                    (updateExpr (varExpr "outer")
                        [ ( "inner", recordExpr [ ( "value", intExpr 99 ) ] ) ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- CALL TYPE TESTS (5 tests)
-- ============================================================================


callTypeTests : (Src.Module -> Expectation) -> String -> Test
callTypeTests expectFn condStr =
    Test.describe ("Call types " ++ condStr)
        [ Test.test ("Simple call type " ++ condStr) (simpleCallType expectFn)
        , Test.test ("Nested call type " ++ condStr) (nestedCallType expectFn)
        , Test.test ("Higher-order call type " ++ condStr) (higherOrderCallType expectFn)
        , Test.test ("Partial application type " ++ condStr) (partialApplicationType expectFn)
        , Test.test ("Call with complex arg type " ++ condStr) (callWithComplexArgType expectFn)
        ]


simpleCallType : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCallType expectFn _ =
    let
        -- negate : Int -> Int
        negateDef : TypedDef
        negateDef =
            { name = "negate"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( intExpr 0, "-" ) ] (varExpr "x")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "negate") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ negateDef, testValueDef ]
    in
    expectFn modul


nestedCallType : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCallType expectFn _ =
    let
        -- double : Int -> Int
        doubleDef : TypedDef
        doubleDef =
            { name = "double"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "double") [ callExpr (varExpr "double") [ intExpr 5 ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ doubleDef, testValueDef ]
    in
    expectFn modul


higherOrderCallType : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderCallType expectFn _ =
    let
        -- apply : (Int -> Int) -> Int -> Int
        applyDef : TypedDef
        applyDef =
            { name = "apply"
            , args = [ pVar "f", pVar "x" ]
            , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tLambda (tType "Int" []) (tType "Int" []))
            , body = callExpr (varExpr "f") [ varExpr "x" ]
            }

        -- inc : Int -> Int
        incDef : TypedDef
        incDef =
            { name = "inc"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "apply") [ varExpr "inc", intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ applyDef, incDef, testValueDef ]
    in
    expectFn modul


partialApplicationType : (Src.Module -> Expectation) -> (() -> Expectation)
partialApplicationType expectFn _ =
    let
        -- add : Int -> Int -> Int
        addDef : TypedDef
        addDef =
            { name = "add"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
            }

        -- add5 : Int -> Int (partial application)
        add5Def : TypedDef
        add5Def =
            { name = "add5"
            , args = []
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "add") [ intExpr 5 ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "add5") [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ addDef, add5Def, testValueDef ]
    in
    expectFn modul


callWithComplexArgType : (Src.Module -> Expectation) -> (() -> Expectation)
callWithComplexArgType expectFn _ =
    let
        -- sumRecord : { x : Int, y : Int } -> Int
        sumRecordDef : TypedDef
        sumRecordDef =
            { name = "sumRecord"
            , args = [ pVar "r" ]
            , tipe = tLambda (tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ]) (tType "Int" [])
            , body = binopsExpr [ ( accessExpr (varExpr "r") "x", "+" ) ] (accessExpr (varExpr "r") "y")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumRecord") [ recordExpr [ ( "x", intExpr 3 ), ( "y", intExpr 4 ) ] ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ sumRecordDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- BINOP TYPE TESTS (5 tests)
-- ============================================================================


binopTypeTests : (Src.Module -> Expectation) -> String -> Test
binopTypeTests expectFn condStr =
    Test.describe ("Binop types " ++ condStr)
        [ Test.test ("Addition binop type " ++ condStr) (additionBinopType expectFn)
        , Test.test ("Comparison binop type " ++ condStr) (comparisonBinopType expectFn)
        , Test.test ("Logical binop type " ++ condStr) (logicalBinopType expectFn)
        , Test.test ("Chained binop type " ++ condStr) (chainedBinopType expectFn)
        , Test.test ("Mixed binop type " ++ condStr) (mixedBinopType expectFn)
        ]


additionBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
additionBinopType expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
    in
    expectFn modul


comparisonBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
comparisonBinopType expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( intExpr 5, ">" ) ] (intExpr 3))
    in
    expectFn modul


logicalBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
logicalBinopType expectFn _ =
    let
        modul =
            makeModule "testValue" (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
    in
    expectFn modul


chainedBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
chainedBinopType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 1, "+" ), ( intExpr 2, "+" ), ( intExpr 3, "+" ) ] (intExpr 4))
    in
    expectFn modul


mixedBinopType : (Src.Module -> Expectation) -> (() -> Expectation)
mixedBinopType expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 2, "*" ), ( intExpr 3, "+" ) ] (intExpr 4))
    in
    expectFn modul



-- ============================================================================
-- NEGATE TYPE TESTS (3 tests)
-- ============================================================================


negateTypeTests : (Src.Module -> Expectation) -> String -> Test
negateTypeTests expectFn condStr =
    Test.describe ("Negate types " ++ condStr)
        [ Test.test ("Negate int type " ++ condStr) (negateIntType expectFn)
        , Test.test ("Negate float type " ++ condStr) (negateFloatType expectFn)
        , Test.test ("Double negate type " ++ condStr) (doubleNegateType expectFn)
        ]


negateIntType : (Src.Module -> Expectation) -> (() -> Expectation)
negateIntType expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


negateFloatType : (Src.Module -> Expectation) -> (() -> Expectation)
negateFloatType expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (floatExpr 3.14))
    in
    expectFn modul


doubleNegateType : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNegateType expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (negateExpr (intExpr 10)))
    in
    expectFn modul
