module SourceIR.SpecializeCycleCases exposing (expectSuite, suite)

{-| Test cases for cycle detection and mutual recursion in Specialize.elm.

These tests cover:

  - MONO\_004: All functions are callable MonoNodes
  - Cycle functions: visitCycleNodes, insertCycleNodePlaceholders, etc.
  - Mutual recursion: value-only and function mutual recursion

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pList
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


suite : Test
suite =
    Test.describe "Specialize.elm cycle coverage"
        [ expectSuite expectMonomorphization "monomorphizes cycles"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Specialize cycles " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ mutualRecursionCases expectFn
        , cycleWithValuesCases expectFn
        , multiNodeCycleCases expectFn
        , benignCycleCases expectFn
        ]



-- ============================================================================
-- MUTUAL RECURSION TESTS
-- ============================================================================


mutualRecursionCases : (Src.Module -> Expectation) -> List TestCase
mutualRecursionCases expectFn =
    [ { label = "Two mutually recursive functions (isEven/isOdd)", run = twoMutuallyRecursiveFns expectFn }
    , { label = "Three mutually recursive functions", run = threeMutuallyRecursiveFns expectFn }
    , { label = "Mutually recursive with different arities", run = mutuallyRecursiveDifferentArities expectFn }
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


cycleWithValuesCases : (Src.Module -> Expectation) -> List TestCase
cycleWithValuesCases expectFn =
    [ { label = "Value depending on recursive function", run = valueWithRecursiveFunction expectFn }
    , { label = "Multiple values in recursive binding group", run = multipleValuesWithRecursion expectFn }
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


multiNodeCycleCases : (Src.Module -> Expectation) -> List TestCase
multiNodeCycleCases expectFn =
    [ { label = "Cycle with polymorphic functions", run = cycleWithPolymorphicFunctions expectFn }
    , { label = "Nested cycles", run = nestedCycles expectFn }
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



-- ============================================================================
-- BENIGN CYCLE TESTS
-- ============================================================================


benignCycleCases : (Src.Module -> Expectation) -> List TestCase
benignCycleCases expectFn =
    [ { label = "Recursive list function with unconstrained element type", run = recursiveListUnconstrained expectFn }
    , { label = "Mutually recursive functions over phantom custom type", run = mutualRecursionPhantomType expectFn }
    ]


{-| Recursive list function whose element type is never constrained.

    process : List a -> List a
    process xs =
        case xs of
            [] ->
                []

            _ :: rest ->
                process rest

    main =
        process []

The type variable `a` is never unified with any concrete type.
This is a benign polymorphic cycle: `a` never affects layout or behaviour.

-}
recursiveListUnconstrained : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveListUnconstrained expectFn _ =
    let
        -- process xs = case xs of [] -> []; _ :: rest -> process rest
        processF =
            define "process"
                [ pVar "xs" ]
                (caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons pAnything (pVar "rest")
                      , callExpr (varExpr "process") [ varExpr "rest" ]
                      )
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ processF ]
                    (callExpr (varExpr "process") [ listExpr [] ])
                )
    in
    expectFn modul


{-| Mutually recursive functions over a phantom custom type.

    type Box a
        = Box

    f : Box a -> Box a
    f x =
        g x

    g : Box a -> Box a
    g x =
        f x

    main =
        f Box

`Box a` is phantom: the constructor carries no payload, so `a` is never
present at runtime. Both `f` and `g` are in a mutual recursion cycle with
an unconstrained type variable -- a benign polymorphic cycle.

-}
mutualRecursionPhantomType : (Src.Module -> Expectation) -> (() -> Expectation)
mutualRecursionPhantomType expectFn _ =
    let
        boxType =
            tType "Box" [ tVar "a" ]

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = [ "a" ]
            , ctors = [ { name = "Box", args = [] } ]
            }

        fDef : TypedDef
        fDef =
            { name = "f"
            , args = [ pVar "x" ]
            , tipe = tLambda boxType boxType
            , body = callExpr (varExpr "g") [ varExpr "x" ]
            }

        gDef : TypedDef
        gDef =
            { name = "g"
            , args = [ pVar "x" ]
            , tipe = tLambda boxType boxType
            , body = callExpr (varExpr "f") [ varExpr "x" ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = boxType
            , body = callExpr (varExpr "f") [ ctorExpr "Box" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "testValue"
                [ fDef, gDef, mainDef ]
                [ boxUnion ]
                []
    in
    expectFn modul
