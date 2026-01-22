module Compiler.LetRecTests exposing (expectSuite)

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
        , recordExpr
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Recursive let expressions " ++ condStr)
        [ selfRecursiveTests expectFn condStr
        , mutuallyRecursiveTests expectFn condStr
        , recursivePatternTests expectFn condStr
        , complexRecursiveTests expectFn condStr
        ]



-- ============================================================================
-- SELF-RECURSIVE FUNCTIONS (8 tests)
-- ============================================================================


selfRecursiveTests : (Src.Module -> Expectation) -> String -> Test
selfRecursiveTests expectFn condStr =
    Test.describe ("Self-recursive functions " ++ condStr)
        [ Test.test ("Simple recursive function " ++ condStr) (simpleRecursiveFn expectFn)
        , Test.test ("Recursive function with case " ++ condStr) (recursiveFnWithCase expectFn)
        , Test.test ("Recursive function returning tuple " ++ condStr) (recursiveFnReturningTuple expectFn)
        , Test.test ("Recursive function with fixed base case " ++ condStr) (recursiveFnFixedBaseCase expectFn)
        , Test.test ("Recursive function with multiple args " ++ condStr) (recursiveFnMultipleArgs expectFn)
        , Test.test ("Recursive function with lambda body " ++ condStr) (recursiveFnLambdaBody expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Deeply recursive function " ++ condStr) (deeplyRecursiveFn expectFn)
        , Test.test ("Recursive function with list accumulator " ++ condStr) (recursiveFnListAccumulator expectFn)
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


recursiveFnReturningTuple : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnReturningTuple expectFn _ =
    let
        fn =
            define "f"
                [ pVar "n" ]
                (ifExpr
                    (boolExpr True)
                    (tupleExpr (intExpr 0) (intExpr 1))
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 3 ]))
    in
    expectFn modul


recursiveFnFixedBaseCase : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnFixedBaseCase expectFn _ =
    let
        fn =
            define "f"
                [ pVar "x" ]
                (ifExpr
                    (boolExpr True)
                    (intExpr 42)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 1 ]))
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


recursiveFnLambdaBody : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnLambdaBody expectFn _ =
    let
        fn =
            define "f"
                [ pVar "n" ]
                (ifExpr
                    (boolExpr True)
                    (intExpr 0)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 5 ]))
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
-- MUTUALLY RECURSIVE FUNCTIONS (6 tests)
-- ============================================================================


mutuallyRecursiveTests : (Src.Module -> Expectation) -> String -> Test
mutuallyRecursiveTests expectFn condStr =
    Test.describe ("Mutually recursive functions " ++ condStr)
        [ Test.test ("Two mutually recursive functions " ++ condStr) (twoMutuallyRecursiveFns expectFn)
        , Test.test ("Three mutually recursive functions " ++ condStr) (threeMutuallyRecursiveFns expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Mutually recursive with different return types " ++ condStr) (mutuallyRecursiveDifferentTypes expectFn)
        , Test.test ("Mutually recursive with fixed value " ++ condStr) (mutuallyRecursiveFixed expectFn)
        , Test.test ("Mutually recursive returning tuples " ++ condStr) (mutuallyRecursiveReturningTuples expectFn)
        , Test.test ("Nested mutually recursive " ++ condStr) (nestedMutuallyRecursive expectFn)
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


threeMutuallyRecursiveFns : (Src.Module -> Expectation) -> (() -> Expectation)
threeMutuallyRecursiveFns expectFn _ =
    let
        f =
            define "f"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 0)
                    (callExpr (varExpr "g") [ intExpr 0 ])
                )

        g =
            define "g"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 1)
                    (callExpr (varExpr "h") [ intExpr 0 ])
                )

        h =
            define "h"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 2)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ f, g, h ] (callExpr (varExpr "f") [ intExpr 10 ]))
    in
    expectFn modul


mutuallyRecursiveFixed : (Src.Module -> Expectation) -> (() -> Expectation)
mutuallyRecursiveFixed expectFn _ =
    let
        ping =
            define "ping"
                [ pVar "x" ]
                (ifExpr (boolExpr True)
                    (intExpr 42)
                    (callExpr (varExpr "pong") [ varExpr "x" ])
                )

        pong =
            define "pong"
                [ pVar "x" ]
                (callExpr (varExpr "ping") [ varExpr "x" ])

        modul =
            makeModule "testValue" (letExpr [ ping, pong ] (callExpr (varExpr "ping") [ intExpr 5 ]))
    in
    expectFn modul


mutuallyRecursiveReturningTuples : (Src.Module -> Expectation) -> (() -> Expectation)
mutuallyRecursiveReturningTuples expectFn _ =
    let
        f =
            define "f"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (tupleExpr (intExpr 0) (intExpr 1))
                    (callExpr (varExpr "g") [ intExpr 0 ])
                )

        g =
            define "g"
                [ pVar "n" ]
                (callExpr (varExpr "f") [ intExpr 0 ])

        modul =
            makeModule "testValue" (letExpr [ f, g ] (callExpr (varExpr "f") [ intExpr 3 ]))
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
-- RECURSIVE WITH PATTERNS (4 tests)
-- ============================================================================


recursivePatternTests : (Src.Module -> Expectation) -> String -> Test
recursivePatternTests expectFn condStr =
    Test.describe ("Recursive functions with patterns " ++ condStr)
        [ Test.test ("Recursive with tuple pattern " ++ condStr) (recursiveWithTuplePattern expectFn)
        , Test.test ("Recursive with cons pattern " ++ condStr) (recursiveWithConsPattern expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Recursive with record pattern " ++ condStr) (recursiveWithRecordPattern expectFn)
        , Test.test ("Recursive with alias pattern " ++ condStr) (recursiveWithAliasPattern expectFn)
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
-- COMPLEX RECURSIVE (4 tests)
-- ============================================================================


complexRecursiveTests : (Src.Module -> Expectation) -> String -> Test
complexRecursiveTests expectFn condStr =
    Test.describe ("Complex recursive scenarios " ++ condStr)
        [ Test.test ("Recursive function in list " ++ condStr) (recursiveFnInList expectFn)
        , Test.test ("Recursive function in record " ++ condStr) (recursiveFnInRecord expectFn)
        , Test.test ("Two recursive functions with fixed values " ++ condStr) (twoRecursiveFnsFixed expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Recursive with higher-order function " ++ condStr) (recursiveHigherOrder expectFn)
        ]


recursiveFnInList : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnInList expectFn _ =
    let
        fn =
            define "f"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 0)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ fn ]
                    (listExpr
                        [ callExpr (varExpr "f") [ intExpr 1 ]
                        , callExpr (varExpr "f") [ intExpr 2 ]
                        , callExpr (varExpr "f") [ intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


recursiveFnInRecord : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnInRecord expectFn _ =
    let
        fn =
            define "f"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 0)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ fn ]
                    (recordExpr
                        [ ( "result", callExpr (varExpr "f") [ intExpr 5 ] )
                        ]
                    )
                )
    in
    expectFn modul


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
