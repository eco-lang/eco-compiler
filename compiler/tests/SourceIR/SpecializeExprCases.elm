module SourceIR.SpecializeExprCases exposing (expectSuite, suite)

{-| Small programs, each built around one kind of expression (a `case`,
self-recursion, or a polymorphic function used at one type), so that a compiler
stage that mishandles that kind of expression can be caught on a program that
holds little else.

The module is named after `specializeExpr` in
`Compiler.Monomorphize.Specialize`, the substitution engine's expression
specializer, and `suite` runs the programs through monomorphization on that
engine.

The fixture is nine programs. Each is a module named `Test`, built with
`makeModuleWithTypedDefsUnionsAliases`, so it imports `Basics`, `Maybe`,
`List`, `Elm.JsArray`, `String` and `Char`, and every top-level definition in
it carries a type annotation. Each defines `testValue`, which
`TestLogic.TestPipeline` needs from typed optimization onwards. The Elm
sketches in the docstrings below are source text for the trees built; the
trees have no `Parens` node where a sketch has parentheses.

The cases only build programs and hand each to an expectation function; what is
checked is that function's choice.

  - `suite` runs the nine cases with
    `TestLogic.TestPipeline.expectMonomorphization`, which passes when
    `runToMono` succeeds and its graph has a `main` and at least one node.
  - `expectSuite` runs the same nine cases with the caller's expectation.
  - Three cases build a `case` on a custom type whose constructors take no
    arguments: one flat, one with a second `case` inside a branch, and one that
    ends with a catch-all branch.
  - One case builds a polymorphic `identity` and applies it to an `Int`.
  - Three cases build self-recursive functions: two with the self-call in tail
    position, which differ only in their names and in the argument `testValue`
    passes, and one (`factorial`) with the self-call as an operand of `*`.
  - One case builds a `case` on `Int` literal patterns, and one a single-branch
    `case` whose branch compares a `String` with `==`.

Among what is not tested: no case uses `Debug`, builds a string literal
pattern, or builds a wildcard pattern (each catch-all branch binds a variable
named `_`). No case checks the value `testValue` would compute, and `suite`
does not run the solver engine.

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
        , ifExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pInt
        , pVar
        , strExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| A single test that runs every case with
`TestLogic.TestPipeline.expectMonomorphization` and reports the first case that
fails.
-}
suite : Test
suite =
    Test.test "Specialize.elm expression coverage monomorphizes expressions" <|
        \_ -> bulkCheck (testCases expectMonomorphization)


{-| Creates a single test, named "Expression specialization " followed by
`condStr`, that runs every case with `expectFn` and reports the first case
that fails.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Expression specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each checked with `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ enumPatternCases expectFn
        , debugExprCases expectFn
        , tailRecursiveCases expectFn
        , literalBranchCases expectFn
        ]



-- ============================================================================
-- ENUM PATTERN TESTS
-- ============================================================================


{-| Returns the three cases that `case` on a custom type whose constructors take
no arguments, each checked with `expectFn`.
-}
enumPatternCases : (Src.Module -> Expectation) -> List TestCase
enumPatternCases expectFn =
    [ { label = "Simple enum case expression", run = simpleEnumCase expectFn }
    , { label = "Nested enum case", run = nestedEnumCase expectFn }
    , { label = "Enum with fallback pattern", run = enumWithFallback expectFn }
    ]


{-| Applies `expectFn` to a program with one `case` that has a branch for each
constructor of a three-constructor type:

    type Status
        = Pending
        | Active
        | Completed

    statusCode : Status -> Int
    statusCode s =
        case s of
            Pending ->
                0

            Active ->
                1

            Completed ->
                2

    testValue : Int
    testValue =
        statusCode Active

-}
simpleEnumCase : (Src.Module -> Expectation) -> (() -> Expectation)
simpleEnumCase expectFn _ =
    let
        statusUnion : UnionDef
        statusUnion =
            { name = "Status"
            , args = []
            , ctors =
                [ { name = "Pending", args = [] }
                , { name = "Active", args = [] }
                , { name = "Completed", args = [] }
                ]
            }

        statusCodeDef : TypedDef
        statusCodeDef =
            { name = "statusCode"
            , args = [ pVar "s" ]
            , tipe = tLambda (tType "Status" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "s")
                    [ ( pCtor "Pending" [], intExpr 0 )
                    , ( pCtor "Active" [], intExpr 1 )
                    , ( pCtor "Completed" [], intExpr 2 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "statusCode") [ ctorExpr "Active" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ statusCodeDef, testValueDef ]
                [ statusUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with a `case` on one argument whose `Red`
branch holds a second `case`, on the other argument; the other two branches
are plain values:

    type Color
        = Red
        | Green
        | Blue

    mixColors : Color -> Color -> Int
    mixColors c1 c2 =
        case c1 of
            Red ->
                case c2 of
                    Red ->
                        16711680

                    Green ->
                        16776960

                    Blue ->
                        16711935

            Green ->
                65280

            Blue ->
                255

    testValue : Int
    testValue =
        mixColors Red Green

-}
nestedEnumCase : (Src.Module -> Expectation) -> (() -> Expectation)
nestedEnumCase expectFn _ =
    let
        colorUnion : UnionDef
        colorUnion =
            { name = "Color"
            , args = []
            , ctors =
                [ { name = "Red", args = [] }
                , { name = "Green", args = [] }
                , { name = "Blue", args = [] }
                ]
            }

        mixColorsDef : TypedDef
        mixColorsDef =
            { name = "mixColors"
            , args = [ pVar "c1", pVar "c2" ]
            , tipe = tLambda (tType "Color" []) (tLambda (tType "Color" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "c1")
                    [ ( pCtor "Red" []
                      , caseExpr (varExpr "c2")
                            [ ( pCtor "Red" [], intExpr 0x00FF0000 )
                            , ( pCtor "Green" [], intExpr 0x00FFFF00 )
                            , ( pCtor "Blue" [], intExpr 0x00FF00FF )
                            ]
                      )
                    , ( pCtor "Green" [], intExpr 0xFF00 )
                    , ( pCtor "Blue" [], intExpr 0xFF )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "mixColors") [ ctorExpr "Red", ctorExpr "Green" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ mixColorsDef, testValueDef ]
                [ colorUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with a `case` on a seven-constructor type
that has branches for two constructors and then a catch-all branch:

    type Day
        = Monday
        | Tuesday
        | Wednesday
        | Thursday
        | Friday
        | Saturday
        | Sunday

    isWeekend : Day -> Bool
    isWeekend day =
        case day of
            Saturday ->
                True

            Sunday ->
                True

            _ ->
                False

    testValue : Bool
    testValue =
        isWeekend Saturday

The catch-all is built with `pVar "_"`, a pattern that binds a variable named
`_`, not the wildcard pattern the parser gives for `_`. `True` and `False` are
references to the `Basics` constructors.

-}
enumWithFallback : (Src.Module -> Expectation) -> (() -> Expectation)
enumWithFallback expectFn _ =
    let
        dayUnion : UnionDef
        dayUnion =
            { name = "Day"
            , args = []
            , ctors =
                [ { name = "Monday", args = [] }
                , { name = "Tuesday", args = [] }
                , { name = "Wednesday", args = [] }
                , { name = "Thursday", args = [] }
                , { name = "Friday", args = [] }
                , { name = "Saturday", args = [] }
                , { name = "Sunday", args = [] }
                ]
            }

        isWeekendDef : TypedDef
        isWeekendDef =
            { name = "isWeekend"
            , args = [ pVar "day" ]
            , tipe = tLambda (tType "Day" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "day")
                    [ ( pCtor "Saturday" [], boolExpr True )
                    , ( pCtor "Sunday" [], boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isWeekend") [ ctorExpr "Saturday" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isWeekendDef, testValueDef ]
                [ dayUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC IDENTITY TEST (labelled as a placeholder for Debug tests)
-- ============================================================================


{-| Returns the one case labelled as a placeholder for `Debug` tests, checked
with `expectFn`. It builds no `Debug` call.
-}
debugExprCases : (Src.Module -> Expectation) -> List TestCase
debugExprCases expectFn =
    [ { label = "Identity function (placeholder for Debug tests)", run = identityFunctionTest expectFn }
    ]


{-| Applies `expectFn` to a program with a polymorphic top-level `identity`
applied to an integer literal at type `Int`:

    identity : a -> a
    identity x =
        x

    testValue : Int
    testValue =
        identity 42

Its label calls it a placeholder for `Debug` tests. It uses no `Debug`, and the
module it builds does not import `Debug`.

-}
identityFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
identityFunctionTest expectFn _ =
    let
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
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ identityDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- TAIL RECURSIVE TESTS
-- ============================================================================


{-| Returns the three self-recursion cases, each checked with `expectFn`: two
with the self-call in tail position and one without.
-}
tailRecursiveCases : (Src.Module -> Expectation) -> List TestCase
tailRecursiveCases expectFn =
    [ { label = "Tail recursive sum", run = tailRecursiveSum expectFn }
    , { label = "Tail recursive with accumulator", run = tailRecursiveWithAccumulator expectFn }
    , { label = "Non-tail recursive for comparison", run = nonTailRecursive expectFn }
    ]


{-| Applies `expectFn` to a program whose helper calls itself in tail position,
in the `else` branch of an `if`, carrying an accumulator:

    sumHelper : Int -> Int -> Int
    sumHelper acc n =
        if n <= 0 then
            acc

        else
            sumHelper (acc + n) (n - 1)

    sum : Int -> Int
    sum n =
        sumHelper 0 n

    testValue : Int
    testValue =
        sum 100

-}
tailRecursiveSum : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecursiveSum expectFn _ =
    let
        sumHelperDef : TypedDef
        sumHelperDef =
            { name = "sumHelper"
            , args = [ pVar "acc", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (callExpr (varExpr "sumHelper")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "n")
                        , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        ]
                    )
            }

        sumDef : TypedDef
        sumDef =
            { name = "sum"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "sumHelper") [ intExpr 0, varExpr "n" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sum") [ intExpr 100 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumHelperDef, sumDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to the same program as `tailRecursiveSum`, with the
helper named `countdownHelper`, the wrapper `countdown`, and `testValue`
defined as `countdown 10`.
-}
tailRecursiveWithAccumulator : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecursiveWithAccumulator expectFn _ =
    let
        countdownHelperDef : TypedDef
        countdownHelperDef =
            { name = "countdownHelper"
            , args = [ pVar "acc", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (callExpr (varExpr "countdownHelper")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "n")
                        , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        ]
                    )
            }

        countdownDef : TypedDef
        countdownDef =
            { name = "countdown"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "countdownHelper") [ intExpr 0, varExpr "n" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "countdown") [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ countdownHelperDef, countdownDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose function calls itself as the right
operand of `*`, so the self-call is not in tail position:

    factorial : Int -> Int
    factorial n =
        if n <= 1 then
            1

        else
            n * factorial (n - 1)

    testValue : Int
    testValue =
        factorial 5

-}
nonTailRecursive : (Src.Module -> Expectation) -> (() -> Expectation)
nonTailRecursive expectFn _ =
    let
        factorialDef : TypedDef
        factorialDef =
            { name = "factorial"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 1))
                    (intExpr 1)
                    (binopsExpr
                        [ ( varExpr "n", "*" ) ]
                        (callExpr (varExpr "factorial")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "factorial") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ factorialDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- INT LITERAL PATTERN AND STRING COMPARISON TESTS
-- ============================================================================


{-| Returns the two cases that branch on a value, each checked with `expectFn`:
one on `Int` literal patterns, and one, labelled "String literal patterns",
that compares a `String` with `==` instead.
-}
literalBranchCases : (Src.Module -> Expectation) -> List TestCase
literalBranchCases expectFn =
    [ { label = "Int literal patterns", run = intLiteralPatterns expectFn }
    , { label = "String literal patterns", run = stringLiteralPatterns expectFn }
    ]


{-| Applies `expectFn` to a program with a `case` on an `Int` that has three
literal patterns and a catch-all branch:

    digitName : Int -> String
    digitName n =
        case n of
            0 ->
                "zero"

            1 ->
                "one"

            2 ->
                "two"

            _ ->
                "other"

    testValue : String
    testValue =
        digitName 1

As in `enumWithFallback`, the catch-all binds a variable named `_`; it is not
a wildcard pattern.

-}
intLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralPatterns expectFn _ =
    let
        digitNameDef : TypedDef
        digitNameDef =
            { name = "digitName"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pInt 2, strExpr "two" )
                    , ( pVar "_", strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "digitName") [ intExpr 1 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ digitNameDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with a single-branch `case` on a `String`
whose one pattern is a variable, and whose branch compares that variable with
`""` using `==`:

    greet : String -> String
    greet name =
        case name of
            n ->
                if n == "" then
                    "Hello, stranger!"

                else
                    "Hello!"

    testValue : String
    testValue =
        greet "Alice"

Despite its label, the program has no string literal pattern.

-}
stringLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
stringLiteralPatterns expectFn _ =
    let
        greetDef : TypedDef
        greetDef =
            { name = "greet"
            , args = [ pVar "name" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body =
                caseExpr (varExpr "name")
                    [ ( pVar "n"
                      , ifExpr
                            (binopsExpr [ ( varExpr "n", "==" ) ] (strExpr ""))
                            (strExpr "Hello, stranger!")
                            (strExpr "Hello!")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "greet") [ strExpr "Alice" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ greetDef, testValueDef ]
                []
                []
    in
    expectFn modul
