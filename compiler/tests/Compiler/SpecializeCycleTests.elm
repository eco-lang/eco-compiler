module Compiler.SpecializeCycleTests exposing (expectSuite, suite)

{-| Test cases for cycle detection and mutual recursion in Specialize.elm.

These tests cover:

  - MONO_004: All functions are callable MonoNodes
  - Cycle functions: visitCycleNodes, insertCycleNodePlaceholders, etc.
  - Mutual recursion: value-only and function mutual recursion

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , accessExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , pCons
        , pCtor
        , pInt
        , pList
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Specialize.elm cycle coverage"
        [ expectSuite expectMonomorphization "monomorphizes cycles"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Specialize cycles " ++ condStr)
        [ mutualRecursionTests expectFn condStr
        , cycleWithValuesTests expectFn condStr
        , multiNodeCycleTests expectFn condStr
        ]



-- ============================================================================
-- MUTUAL RECURSION TESTS
-- ============================================================================


mutualRecursionTests : (Src.Module -> Expectation) -> String -> Test
mutualRecursionTests expectFn condStr =
    Test.describe ("Mutual recursion " ++ condStr)
        [ Test.test "Two mutually recursive functions (isEven/isOdd)" <|
            twoMutuallyRecursiveFns expectFn
        , Test.test "Three mutually recursive functions" <|
            threeMutuallyRecursiveFns expectFn
        , Test.test "Mutually recursive with different arities" <|
            mutuallyRecursiveDifferentArities expectFn
        ]


{-| Classic isEven/isOdd mutual recursion pattern.
Tests visitCycleNodes and insertCycleNodePlaceholders.
-}
twoMutuallyRecursiveFns : (Src.Module -> Expectation) -> (() -> Expectation)
twoMutuallyRecursiveFns expectFn _ =
    let
        -- isEven n = if n == 0 then True else isOdd (n - 1)
        isEven =
            define "isEven"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (boolExpr True)
                    (callExpr (varExpr "isOdd")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        -- isOdd n = if n == 0 then False else isEven (n - 1)
        isOdd =
            define "isOdd"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (boolExpr False)
                    (callExpr (varExpr "isEven")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        -- testValue = isEven 10
        modul =
            makeModule "testValue"
                (letExpr [ isEven, isOdd ]
                    (callExpr (varExpr "isEven") [ intExpr 10 ])
                )
    in
    expectFn modul


{-| Three functions in a cycle: A -> B -> C -> A.
Tests handling of larger cycles.
-}
threeMutuallyRecursiveFns : (Src.Module -> Expectation) -> (() -> Expectation)
threeMutuallyRecursiveFns expectFn _ =
    let
        -- funcA n = if n <= 0 then 0 else funcB (n - 1)
        funcA =
            define "funcA"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 0)
                    (callExpr (varExpr "funcB")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        -- funcB n = if n <= 0 then 1 else funcC (n - 1)
        funcB =
            define "funcB"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 1)
                    (callExpr (varExpr "funcC")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        -- funcC n = if n <= 0 then 2 else funcA (n - 1)
        funcC =
            define "funcC"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 2)
                    (callExpr (varExpr "funcA")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ funcA, funcB, funcC ]
                    (callExpr (varExpr "funcA") [ intExpr 10 ])
                )
    in
    expectFn modul


{-| Mutually recursive functions with different arities.
-}
mutuallyRecursiveDifferentArities : (Src.Module -> Expectation) -> (() -> Expectation)
mutuallyRecursiveDifferentArities expectFn _ =
    let
        -- singleArg n = if n <= 0 then 0 else doubleArg n 1
        singleArg =
            define "singleArg"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 0)
                    (callExpr (varExpr "doubleArg")
                        [ varExpr "n", intExpr 1 ]
                    )
                )

        -- doubleArg a b = if a <= 0 then b else singleArg (a - b)
        doubleArg =
            define "doubleArg"
                [ pVar "a", pVar "b" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "a", "<=" ) ] (intExpr 0))
                    (varExpr "b")
                    (callExpr (varExpr "singleArg")
                        [ binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b") ]
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ singleArg, doubleArg ]
                    (callExpr (varExpr "singleArg") [ intExpr 5 ])
                )
    in
    expectFn modul



-- ============================================================================
-- CYCLE WITH VALUES TESTS
-- ============================================================================


cycleWithValuesTests : (Src.Module -> Expectation) -> String -> Test
cycleWithValuesTests expectFn condStr =
    Test.describe ("Cycles with values " ++ condStr)
        [ Test.test "Value depending on recursive function" <|
            valueWithRecursiveFunction expectFn
        , Test.test "Multiple values in recursive binding group" <|
            multipleValuesWithRecursion expectFn
        ]


{-| A value that depends on a recursive function.
-}
valueWithRecursiveFunction : (Src.Module -> Expectation) -> (() -> Expectation)
valueWithRecursiveFunction expectFn _ =
    let
        -- factorial n = if n <= 1 then 1 else n * factorial (n - 1)
        factorial =
            define "factorial"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 1))
                    (intExpr 1)
                    (binopsExpr
                        [ ( varExpr "n", "*" ) ]
                        (callExpr (varExpr "factorial")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                        )
                    )
                )

        -- result = factorial 5
        result =
            define "result" [] (callExpr (varExpr "factorial") [ intExpr 5 ])

        modul =
            makeModule "testValue"
                (letExpr [ factorial, result ]
                    (varExpr "result")
                )
    in
    expectFn modul


{-| Multiple values in a recursive binding group.
-}
multipleValuesWithRecursion : (Src.Module -> Expectation) -> (() -> Expectation)
multipleValuesWithRecursion expectFn _ =
    let
        -- countdown n = if n <= 0 then [] else n :: countdown (n - 1)
        countdown =
            define "countdown"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (listExpr [])
                    (binopsExpr
                        [ ( varExpr "n", "::" ) ]
                        (callExpr (varExpr "countdown")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                        )
                    )
                )

        -- numbers = countdown 5
        numbers =
            define "numbers" [] (callExpr (varExpr "countdown") [ intExpr 5 ])

        -- sum = List.foldr (+) 0 numbers (represented as simpler expression)
        sumVal =
            define "sumVal" [] (callExpr (varExpr "countdown") [ intExpr 3 ])

        modul =
            makeModule "testValue"
                (letExpr [ countdown, numbers, sumVal ]
                    (varExpr "numbers")
                )
    in
    expectFn modul



-- ============================================================================
-- MULTI-NODE CYCLE TESTS
-- ============================================================================


multiNodeCycleTests : (Src.Module -> Expectation) -> String -> Test
multiNodeCycleTests expectFn condStr =
    Test.describe ("Multi-node cycles " ++ condStr)
        [ Test.test "Cycle with polymorphic functions" <|
            cycleWithPolymorphicFunctions expectFn
        , Test.test "Nested cycles" <|
            nestedCycles expectFn
        ]


{-| Cycle involving polymorphic functions.
Tests specialization of cycles with type variables.
-}
cycleWithPolymorphicFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
cycleWithPolymorphicFunctions expectFn _ =
    let
        -- process xs = if List.isEmpty xs then [] else transform xs
        processF =
            define "process"
                [ pVar "xs" ]
                (caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pVar "nonEmpty", callExpr (varExpr "transform") [ varExpr "nonEmpty" ] )
                    ]
                )

        -- transform xs = process (List.drop 1 xs)
        -- Simplified: transform xs = process xs
        transformF =
            define "transform"
                [ pVar "xs" ]
                (callExpr (varExpr "process") [ varExpr "xs" ])

        modul =
            makeModule "testValue"
                (letExpr [ processF, transformF ]
                    (callExpr (varExpr "process") [ listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul


{-| Nested cycles - cycles within cycles.
-}
nestedCycles : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCycles expectFn _ =
    let
        -- outer function with inner recursive let
        outerFn =
            define "outer"
                [ pVar "n" ]
                (letExpr
                    [ define "inner"
                        [ pVar "m" ]
                        (ifExpr
                            (binopsExpr [ ( varExpr "m", "<=" ) ] (intExpr 0))
                            (intExpr 0)
                            (callExpr (varExpr "inner")
                                [ binopsExpr [ ( varExpr "m", "-" ) ] (intExpr 1) ]
                            )
                        )
                    ]
                    (callExpr (varExpr "inner") [ varExpr "n" ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ outerFn ]
                    (callExpr (varExpr "outer") [ intExpr 5 ])
                )
    in
    expectFn modul
