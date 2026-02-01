module SourceIR.LetRecCases exposing (expectSuite, testCases)

{-| Tests for mutually recursive let expressions.
Note: In Elm, mutually recursive functions are detected automatically,
but we test that the canonicalizer handles recursive references properly.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , pAlias
        , pCons
        , pList
        , pTuple
        , pVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let rec expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    selfRecursiveCases expectFn
        ++ mutuallyRecursiveCases expectFn
        ++ recursivePatternCases expectFn
        ++ complexRecursiveCases expectFn



-- ============================================================================
-- SELF-RECURSIVE FUNCTIONS
-- ============================================================================


selfRecursiveCases : (Src.Module -> Expectation) -> List TestCase
selfRecursiveCases expectFn =
    [ { label = "Simple recursive function", run = simpleRecursiveFn expectFn }
    , { label = "Recursive function with case", run = recursiveFnWithCase expectFn }
    , { label = "Recursive function with multiple args", run = recursiveFnMultipleArgs expectFn }
    , { label = "Recursive function with list accumulator", run = recursiveFnListAccumulator expectFn }
    ]


simpleRecursiveFn : (Src.Module -> Expectation) -> (() -> Expectation)
simpleRecursiveFn expectFn _ =
    let
        -- factorial-like: if n == 0 then 1 else f(n-1)
        fn =
            define "f"
                [ pVar "n" ]
                (ifExpr
                    (boolExpr True)
                    (intExpr 1)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 5 ]))
    in
    expectFn modul


recursiveFnWithCase : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnWithCase expectFn _ =
    let
        fn =
            define "len"
                [ pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], intExpr 0 )
                    , ( pCons (pVar "h") (pVar "t"), callExpr (varExpr "len") [ varExpr "t" ] )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "len") [ listExpr [ intExpr 1, intExpr 2 ] ]))
    in
    expectFn modul


recursiveFnMultipleArgs : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnMultipleArgs expectFn _ =
    let
        fn =
            define "f"
                [ pVar "a", pVar "b" ]
                (ifExpr
                    (boolExpr True)
                    (varExpr "b")
                    (callExpr (varExpr "f") [ varExpr "b", varExpr "a" ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 1, intExpr 2 ]))
    in
    expectFn modul


recursiveFnListAccumulator : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnListAccumulator expectFn _ =
    let
        fn =
            define "collect"
                [ pVar "n", pVar "acc" ]
                (ifExpr
                    (boolExpr True)
                    (varExpr "acc")
                    (callExpr (varExpr "collect") [ intExpr 0, listExpr [ varExpr "n" ] ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "collect") [ intExpr 5, listExpr [] ]))
    in
    expectFn modul



-- ============================================================================
-- MUTUALLY RECURSIVE FUNCTIONS
-- ============================================================================


mutuallyRecursiveCases : (Src.Module -> Expectation) -> List TestCase
mutuallyRecursiveCases expectFn =
    [ { label = "Two mutually recursive functions", run = twoMutuallyRecursiveFns expectFn }
    , { label = "Nested mutually recursive", run = nestedMutuallyRecursive expectFn }
    ]


twoMutuallyRecursiveFns : (Src.Module -> Expectation) -> (() -> Expectation)
twoMutuallyRecursiveFns expectFn _ =
    let
        isEven =
            define "isEven"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (boolExpr True)
                    (callExpr (varExpr "isOdd") [ intExpr 0 ])
                )

        isOdd =
            define "isOdd"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (boolExpr False)
                    (callExpr (varExpr "isEven") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ isEven, isOdd ] (callExpr (varExpr "isEven") [ intExpr 4 ]))
    in
    expectFn modul


nestedMutuallyRecursive : (Src.Module -> Expectation) -> (() -> Expectation)
nestedMutuallyRecursive expectFn _ =
    let
        outer =
            define "outer"
                [ pVar "n" ]
                (letExpr
                    [ define "inner1"
                        [ pVar "x" ]
                        (ifExpr (boolExpr True) (intExpr 0) (callExpr (varExpr "inner2") [ varExpr "x" ]))
                    , define "inner2"
                        [ pVar "x" ]
                        (callExpr (varExpr "inner1") [ varExpr "x" ])
                    ]
                    (callExpr (varExpr "inner1") [ varExpr "n" ])
                )

        modul =
            makeModule "testValue" (letExpr [ outer ] (callExpr (varExpr "outer") [ intExpr 5 ]))
    in
    expectFn modul



-- ============================================================================
-- RECURSIVE WITH PATTERNS
-- ============================================================================


recursivePatternCases : (Src.Module -> Expectation) -> List TestCase
recursivePatternCases expectFn =
    [ { label = "Recursive with tuple pattern", run = recursiveWithTuplePattern expectFn }
    , { label = "Recursive with cons pattern", run = recursiveWithConsPattern expectFn }
    , { label = "Recursive with alias pattern", run = recursiveWithAliasPattern expectFn }
    ]


recursiveWithTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithTuplePattern expectFn _ =
    let
        fn =
            define "process"
                [ pTuple (pVar "a") (pVar "b") ]
                (ifExpr (boolExpr True)
                    (intExpr 0)
                    (callExpr (varExpr "process") [ tupleExpr (varExpr "b") (varExpr "a") ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "process") [ tupleExpr (intExpr 1) (intExpr 2) ]))
    in
    expectFn modul


recursiveWithConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithConsPattern expectFn _ =
    let
        fn =
            define "sum"
                [ pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], intExpr 0 )
                    , ( pCons (pVar "h") (pVar "t"), callExpr (varExpr "sum") [ varExpr "t" ] )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "sum") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]))
    in
    expectFn modul


recursiveWithAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithAliasPattern expectFn _ =
    let
        fn =
            define "process"
                [ pAlias (pVar "x") "whole" ]
                (ifExpr (boolExpr True)
                    (tupleExpr (varExpr "x") (varExpr "whole"))
                    (callExpr (varExpr "process") [ varExpr "x" ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "process") [ intExpr 5 ]))
    in
    expectFn modul



-- ============================================================================
-- COMPLEX RECURSIVE
-- ============================================================================


complexRecursiveCases : (Src.Module -> Expectation) -> List TestCase
complexRecursiveCases expectFn =
    [ { label = "Two recursive functions with fixed values", run = twoRecursiveFnsFixed expectFn }
    ]


twoRecursiveFnsFixed : (Src.Module -> Expectation) -> (() -> Expectation)
twoRecursiveFnsFixed expectFn _ =
    let
        f =
            define "f"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 1)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        g =
            define "g"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 2)
                    (callExpr (varExpr "g") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ f, g ]
                    (tupleExpr
                        (callExpr (varExpr "f") [ intExpr 1 ])
                        (callExpr (varExpr "g") [ intExpr 2 ])
                    )
                )
    in
    expectFn modul
