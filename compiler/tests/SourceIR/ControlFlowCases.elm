module SourceIR.ControlFlowCases exposing (expectSuite, suite)

{-| Small programs built around `if` chains, the `&&` and `||` operators and
`not`, for the pipeline-stage tests to compile. In each one, conditionals and
boolean operators are most of the code.

The module asserts nothing itself. `expectSuite` takes an expectation function,
which decides how far each program is compiled and what counts as passing, and
puts all seventeen cases in one test with `Compiler.BulkCheck.bulkCheck`, so a
failure names the first failing case and the cases after it are not run. A
case that crashes, rather than failing, ends the test without being named.
`suite` runs that test with `TestLogic.TestPipeline.expectMonomorphization` as
the expectation: `runToMono` must succeed and give a graph with a `main` and at
least one node.

Each program is a module named `Test`, made by
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`, so it imports
`Basics`, `Maybe`, `List`, `Elm.JsArray as JsArray`, `String` and `Char`, and it
declares no custom types or aliases. Every top-level definition is annotated,
and the annotations fix every integer literal to `Int`. Each program defines a
`testValue` that applies the function under test to fixed arguments, which
`TestLogic.TestPipeline` needs from typed optimization onwards.

Each case's docstring sketches its program as Elm source. Apart from source
positions, the tree differs from what the parser would give for that source in
three ways. An `else if` is a separate `if` nested in the `else` branch, where
the parser builds one `if` holding every condition. An operator chain used as
an operand or as a call argument is a nested chain with no `Parens` node. A
negative number such as `-1` is a negative literal, where the parser builds a
negation.

The cases fall into four groups:

  - Multi-way `if`: chains with three, four and five outcomes; two nested
    `if`s whose conditions call other top-level functions; and an `if`
    choosing between two lists.
  - Short-circuit operators: one `&&`; one `||`; an `&&` inside an `||`; and an
    `&&` of two function calls.
  - Compound boolean expressions: three-operand `&&` and `||` chains; two `&&`
    expressions joined by `||`; and `not` applied to a comparison.
  - Nested conditionals: an `if` in the `then` branch, in the `else` branch, in
    both, and five `if`s, each but the first nested in the `else` branch of the
    one before.

Among what is not tested:

  - The value any program computes, or whether `&&` and `||` skip their right
    operand: nothing here evaluates a program, and `suite`'s expectation stops
    at monomorphization.
  - `&&`, `||` or `not` passed as a function value rather than applied.
  - `case` expressions: no program has one.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| A test that checks the cases in order with
`TestLogic.TestPipeline.expectMonomorphization`, stopping at the first that
fails. That expectation requires `runToMono` to succeed and give a graph with a
`main` and at least one node.
-}
suite : Test
suite =
    Test.describe "Control flow coverage"
        [ expectSuite expectMonomorphization "monomorphizes control flow"
        ]


{-| Creates one test, named `"Control flow "` followed by `condStr`, that
applies `expectFn` to each case's program in turn and passes when every case
passes. The first failing case ends the test, and the failure names it.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Control flow " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the seventeen cases of the four groups, in group order, each
applying `expectFn` to its program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ multiWayIfCases expectFn
        , booleanShortCircuitCases expectFn
        , complexBooleanCases expectFn
        , nestedConditionalCases expectFn
        ]



-- ============================================================================
-- MULTI-WAY IF TESTS
-- ============================================================================


{-| Returns the five cases of the multi-way `if` group, each applying
`expectFn` to its program.
-}
multiWayIfCases : (Src.Module -> Expectation) -> List TestCase
multiWayIfCases expectFn =
    [ { label = "Three-way if", run = threeWayIfTest expectFn }
    , { label = "Four-way if", run = fourWayIfTest expectFn }
    , { label = "Five-way if", run = fiveWayIfTest expectFn }
    , { label = "If with function calls in conditions", run = ifWithFunctionCallsTest expectFn }
    , { label = "If returning different types of expressions", run = ifReturningExpressionsTest expectFn }
    ]


{-| Applies `expectFn` to a program whose `sign` chooses among three results
with two `if`s, and whose `testValue` is `sign 42`:

    sign : Int -> Int
    sign n =
        if n < 0 then
            -1

        else if n > 0 then
            1

        else
            0

-}
threeWayIfTest : (Src.Module -> Expectation) -> (() -> Expectation)
threeWayIfTest expectFn _ =
    let
        signDef : TypedDef
        signDef =
            { name = "sign"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                    (intExpr -1)
                    (ifExpr
                        (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
                        (intExpr 1)
                        (intExpr 0)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sign") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ signDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `classify` chooses among four results
with three `if`s, and whose `testValue` is `classify 50`:

    classify : Int -> String
    classify n =
        if n < 0 then
            "negative"

        else if n == 0 then
            "zero"

        else if n < 10 then
            "small"

        else
            "large"

-}
fourWayIfTest : (Src.Module -> Expectation) -> (() -> Expectation)
fourWayIfTest expectFn _ =
    let
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                    (strExpr "negative")
                    (ifExpr
                        (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                        (strExpr "zero")
                        (ifExpr
                            (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 10))
                            (strExpr "small")
                            (strExpr "large")
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "classify") [ intExpr 50 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `grade` chooses among five results
with four `if`s, and whose `testValue` is `grade 75`:

    grade : Int -> String
    grade score =
        if score >= 90 then
            "A"

        else if score >= 80 then
            "B"

        else if score >= 70 then
            "C"

        else if score >= 60 then
            "D"

        else
            "F"

-}
fiveWayIfTest : (Src.Module -> Expectation) -> (() -> Expectation)
fiveWayIfTest expectFn _ =
    let
        gradeDef : TypedDef
        gradeDef =
            { name = "grade"
            , args = [ pVar "score" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 90))
                    (strExpr "A")
                    (ifExpr
                        (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 80))
                        (strExpr "B")
                        (ifExpr
                            (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 70))
                            (strExpr "C")
                            (ifExpr
                                (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 60))
                                (strExpr "D")
                                (strExpr "F")
                            )
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "grade") [ intExpr 75 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ gradeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `if` conditions are calls to other
top-level functions, and whose `testValue` is `categorize 4`:

    isPositive : Int -> Bool
    isPositive n =
        n > 0

    isEven : Int -> Bool
    isEven n =
        n // 2 * 2 == n

    categorize : Int -> String
    categorize n =
        if isPositive n then
            if isEven n then
                "positive even"

            else
                "positive odd"

        else
            "non-positive"

-}
ifWithFunctionCallsTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithFunctionCallsTest expectFn _ =
    let
        isPositiveDef : TypedDef
        isPositiveDef =
            { name = "isPositive"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0)
            }

        isEvenDef : TypedDef
        isEvenDef =
            { name = "isEven"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "n", "//" ) ] (intExpr 2), "*" )
                    , ( intExpr 2, "==" )
                    ]
                    (varExpr "n")
            }

        categorizeDef : TypedDef
        categorizeDef =
            { name = "categorize"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                ifExpr
                    (callExpr (varExpr "isPositive") [ varExpr "n" ])
                    (ifExpr
                        (callExpr (varExpr "isEven") [ varExpr "n" ])
                        (strExpr "positive even")
                        (strExpr "positive odd")
                    )
                    (strExpr "non-positive")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "categorize") [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isPositiveDef, isEvenDef, categorizeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `if` chooses between a three-element
list and an empty one, and whose `testValue` is `selectList Basics.True`:

    selectList : Bool -> List Int
    selectList flag =
        if flag then
            [ 1, 2, 3 ]

        else
            []

Despite the case's label, both branches have the type `List Int`.

-}
ifReturningExpressionsTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningExpressionsTest expectFn _ =
    let
        selectListDef : TypedDef
        selectListDef =
            { name = "selectList"
            , args = [ pVar "flag" ]
            , tipe = tLambda (tType "Bool" []) (tType "List" [ tType "Int" [] ])
            , body =
                ifExpr
                    (varExpr "flag")
                    (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
                    (listExpr [])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body = callExpr (varExpr "selectList") [ boolExpr True ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ selectListDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- BOOLEAN SHORT-CIRCUIT TESTS
-- ============================================================================


{-| Returns the four cases built around one or two `&&` and `||` operators,
each applying `expectFn` to its program.
-}
booleanShortCircuitCases : (Src.Module -> Expectation) -> List TestCase
booleanShortCircuitCases expectFn =
    [ { label = "And short-circuit", run = andShortCircuitTest expectFn }
    , { label = "Or short-circuit", run = orShortCircuitTest expectFn }
    , { label = "Mixed and/or", run = mixedAndOrTest expectFn }
    , { label = "Short-circuit with function calls", run = shortCircuitWithFunctionCallsTest expectFn }
    ]


{-| Applies `expectFn` to a program whose `safeDivide` is one `&&` of two
comparisons, the second containing a division, and whose `testValue` is
`safeDivide 10 2`:

    safeDivide : Int -> Int -> Bool
    safeDivide a b =
        b /= 0 && a // b > 0

-}
andShortCircuitTest : (Src.Module -> Expectation) -> (() -> Expectation)
andShortCircuitTest expectFn _ =
    let
        safeDivideDef : TypedDef
        safeDivideDef =
            { name = "safeDivide"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Bool" []))
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "b", "/=" ) ] (intExpr 0), "&&" ) ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "//" ) ] (varExpr "b"), ">" ) ]
                        (intExpr 0)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "safeDivide") [ intExpr 10, intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ safeDivideDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `isZeroOrPositive` is one `||` of two
comparisons, and whose `testValue` is `isZeroOrPositive 0`:

    isZeroOrPositive : Int -> Bool
    isZeroOrPositive n =
        n == 0 || n > 0

-}
orShortCircuitTest : (Src.Module -> Expectation) -> (() -> Expectation)
orShortCircuitTest expectFn _ =
    let
        isZeroOrPositiveDef : TypedDef
        isZeroOrPositiveDef =
            { name = "isZeroOrPositive"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0), "||" ) ]
                    (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isZeroOrPositive") [ intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isZeroOrPositiveDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `inRange` has an `&&` as the left
operand of an `||`, and whose `testValue` is `inRange 1 10 5`:

    inRange : Int -> Int -> Int -> Bool
    inRange lo hi x =
        (x >= lo && x <= hi) || x == 0

-}
mixedAndOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
mixedAndOrTest expectFn _ =
    let
        inRangeDef : TypedDef
        inRangeDef =
            { name = "inRange"
            , args = [ pVar "lo", pVar "hi", pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Bool" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr
                            [ ( binopsExpr [ ( varExpr "x", ">=" ) ] (varExpr "lo"), "&&" ) ]
                            (binopsExpr [ ( varExpr "x", "<=" ) ] (varExpr "hi"))
                      , "||"
                      )
                    ]
                    (binopsExpr [ ( varExpr "x", "==" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "inRange") [ intExpr 1, intExpr 10, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ inRangeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `checkBoth` is an `&&` of two calls to
other top-level functions, and whose `testValue` is `checkBoth 50`:

    isValid : Int -> Bool
    isValid n =
        n > 0

    isSmall : Int -> Bool
    isSmall n =
        n < 100

    checkBoth : Int -> Bool
    checkBoth n =
        isValid n && isSmall n

-}
shortCircuitWithFunctionCallsTest : (Src.Module -> Expectation) -> (() -> Expectation)
shortCircuitWithFunctionCallsTest expectFn _ =
    let
        isValidDef : TypedDef
        isValidDef =
            { name = "isValid"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0)
            }

        isSmallDef : TypedDef
        isSmallDef =
            { name = "isSmall"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 100)
            }

        checkBothDef : TypedDef
        checkBothDef =
            { name = "checkBoth"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body =
                binopsExpr
                    [ ( callExpr (varExpr "isValid") [ varExpr "n" ], "&&" ) ]
                    (callExpr (varExpr "isSmall") [ varExpr "n" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "checkBoth") [ intExpr 50 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isValidDef, isSmallDef, checkBothDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- COMPLEX BOOLEAN TESTS
-- ============================================================================


{-| Returns the four compound boolean cases, each applying `expectFn` to its
program.
-}
complexBooleanCases : (Src.Module -> Expectation) -> List TestCase
complexBooleanCases expectFn =
    [ { label = "Triple and", run = tripleAndTest expectFn }
    , { label = "Triple or", run = tripleOrTest expectFn }
    , { label = "Nested boolean expressions", run = nestedBooleanExpressionsTest expectFn }
    , { label = "Boolean with not", run = booleanWithNotTest expectFn }
    ]


{-| Applies `expectFn` to a program whose `allPositive` is one chain of two
`&&`s over three comparisons, and whose `testValue` is `allPositive 1 2 3`:

    allPositive : Int -> Int -> Int -> Bool
    allPositive a b c =
        a > 0 && b > 0 && c > 0

-}
tripleAndTest : (Src.Module -> Expectation) -> (() -> Expectation)
tripleAndTest expectFn _ =
    let
        allPositiveDef : TypedDef
        allPositiveDef =
            { name = "allPositive"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Bool" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0), "&&" )
                    , ( binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0), "&&" )
                    ]
                    (binopsExpr [ ( varExpr "c", ">" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "allPositive") [ intExpr 1, intExpr 2, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ allPositiveDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `anyZero` is one chain of two `||`s
over three comparisons, and whose `testValue` is `anyZero 1 0 3`:

    anyZero : Int -> Int -> Int -> Bool
    anyZero a b c =
        a == 0 || b == 0 || c == 0

-}
tripleOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOrTest expectFn _ =
    let
        anyZeroDef : TypedDef
        anyZeroDef =
            { name = "anyZero"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Bool" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "a", "==" ) ] (intExpr 0), "||" )
                    , ( binopsExpr [ ( varExpr "b", "==" ) ] (intExpr 0), "||" )
                    ]
                    (binopsExpr [ ( varExpr "c", "==" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "anyZero") [ intExpr 1, intExpr 0, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ anyZeroDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `complexCheck` joins two `&&`
expressions with `||`, and whose `testValue` is `complexCheck -1 -2`:

    complexCheck : Int -> Int -> Bool
    complexCheck a b =
        (a > 0 && b > 0) || (a < 0 && b < 0)

-}
nestedBooleanExpressionsTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedBooleanExpressionsTest expectFn _ =
    let
        complexCheckDef : TypedDef
        complexCheckDef =
            { name = "complexCheck"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Bool" []))
            , body =
                binopsExpr
                    [ ( binopsExpr
                            [ ( binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0), "&&" ) ]
                            (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                      , "||"
                      )
                    ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "<" ) ] (intExpr 0), "&&" ) ]
                        (binopsExpr [ ( varExpr "b", "<" ) ] (intExpr 0))
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "complexCheck") [ intExpr -1, intExpr -2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ complexCheckDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `notPositive` calls `not` on a
comparison, and whose `testValue` is `notPositive -5`:

    notPositive : Int -> Bool
    notPositive n =
        not (n > 0)

-}
booleanWithNotTest : (Src.Module -> Expectation) -> (() -> Expectation)
booleanWithNotTest expectFn _ =
    let
        notPositiveDef : TypedDef
        notPositiveDef =
            { name = "notPositive"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = callExpr (varExpr "not") [ binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "notPositive") [ intExpr -5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ notPositiveDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED CONDITIONAL TESTS
-- ============================================================================


{-| Returns the four nested `if` cases, each applying `expectFn` to its program.
-}
nestedConditionalCases : (Src.Module -> Expectation) -> List TestCase
nestedConditionalCases expectFn =
    [ { label = "If in if branch", run = ifInIfBranchTest expectFn }
    , { label = "If in else branch", run = ifInElseBranchTest expectFn }
    , { label = "If in both branches", run = ifInBothBranchesTest expectFn }
    , { label = "Deep nesting", run = deepNestingTest expectFn }
    ]


{-| Applies `expectFn` to a program whose `nestedIf` has an `if` in its `then`
branch, and whose `testValue` is `nestedIf 5 10`:

    nestedIf : Int -> Int -> Int
    nestedIf a b =
        if a > 0 then
            if b > 0 then
                1

            else
                2

        else
            3

-}
ifInIfBranchTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifInIfBranchTest expectFn _ =
    let
        nestedIfDef : TypedDef
        nestedIfDef =
            { name = "nestedIf"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0))
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 1)
                        (intExpr 2)
                    )
                    (intExpr 3)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "nestedIf") [ intExpr 5, intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ nestedIfDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `elseNested` has an `if` in its `else`
branch, and whose `testValue` is `elseNested -1 10`:

    elseNested : Int -> Int -> Int
    elseNested a b =
        if a > 0 then
            1

        else if b > 0 then
            2

        else
            3

-}
ifInElseBranchTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifInElseBranchTest expectFn _ =
    let
        elseNestedDef : TypedDef
        elseNestedDef =
            { name = "elseNested"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0))
                    (intExpr 1)
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 2)
                        (intExpr 3)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "elseNested") [ intExpr -1, intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ elseNestedDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `bothNested` has an `if` in each
branch, both testing `b`, and whose `testValue` is `bothNested -1 -2`:

    bothNested : Int -> Int -> Int
    bothNested a b =
        if a > 0 then
            if b > 0 then
                1

            else
                2

        else if b > 0 then
            3

        else
            4

-}
ifInBothBranchesTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifInBothBranchesTest expectFn _ =
    let
        bothNestedDef : TypedDef
        bothNestedDef =
            { name = "bothNested"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0))
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 1)
                        (intExpr 2)
                    )
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 3)
                        (intExpr 4)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "bothNested") [ intExpr -1, intExpr -2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ bothNestedDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `deepNest` has five `if`s, each but
the first in the `else` branch of the one before, and whose `testValue` is
`deepNest 30`:

    deepNest : Int -> Int
    deepNest n =
        if n > 100 then
            5

        else if n > 50 then
            4

        else if n > 25 then
            3

        else if n > 10 then
            2

        else if n > 0 then
            1

        else
            0

-}
deepNestingTest : (Src.Module -> Expectation) -> (() -> Expectation)
deepNestingTest expectFn _ =
    let
        deepNestDef : TypedDef
        deepNestDef =
            { name = "deepNest"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 100))
                    (intExpr 5)
                    (ifExpr
                        (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 50))
                        (intExpr 4)
                        (ifExpr
                            (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 25))
                            (intExpr 3)
                            (ifExpr
                                (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 10))
                                (intExpr 2)
                                (ifExpr
                                    (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
                                    (intExpr 1)
                                    (intExpr 0)
                                )
                            )
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "deepNest") [ intExpr 30 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ deepNestDef, testValueDef ]
                []
                []
    in
    expectFn modul
