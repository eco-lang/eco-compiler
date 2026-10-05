module SourceIR.JoinpointABICases exposing (expectSuite, suite)

{-| Programs in which the branches of a `case` return functions, for testing a
compiler stage on the place where those branches meet.

Elm lets two lambdas of the same type group their parameters differently:
`\a b -> \c -> a + b + c` and `\a -> \b c -> a + b + c` both have type
`Int -> Int -> Int -> Int`. How a function value groups its parameters into
lambda layers is its _segmentation_, written as the parameter count of each
layer, so these two are `[2, 1]` and `[1, 2]`; a function with more than one
layer is _staged_. When the branches of a `case` return functions, the value
leaving the `case` must be callable one way whichever branch produced it. The
point where the branches meet is the _join point_, and the segmentation every
branch must present there is its _ABI_. `Compiler.GlobalOpt.Staging` is the
pass that picks one segmentation for the function values it joins at a join
point, by a majority vote that `Compiler.GlobalOpt.Staging.Solver` owns, and
wraps those that differ from it. Which branches it joins is a rule
`Compiler.GlobalOpt.Staging.GraphBuilder` owns. The categories below are
arranged by how the segmentations of the branches, as written, compare.

Every case builds a module `Test` with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`, holding two
annotated top-level definitions. `caseFunc` names one or two parameters and
its body is a `case` on the first of them. Except in 1.6, its annotation has
more arrows than it names parameters, and the remaining arguments are taken by
the lambdas its branches return. Every argument and result is an `Int`, except
the second parameter of `ifInCaseBranch` (a `Bool`) and the scrutinee in
`recordPatternBranches` (a record `{ tag : Int, k : Int }`),
`customTypeBranches` (a `MaybeInt`, the one union any case declares) and
`listPatternBranches` (a `List Int`). `testValue : Int` applies `caseFunc` to
literals, sometimes in one call and sometimes in several: integer literals
except for `True` in 4.2 and those three scrutinees,
`{ tag = 0, k = 1 }` in 5.4, `JustInt 10` in 5.5 and `[ 10, 20 ]` in 5.6. Where a docstring gives `testValue` as
`(caseFunc 0 5) 3`, the built tree holds one call as the function of another,
with no `Parens` node.

What the tests establish:

  - `expectSuite expectFn condStr` is one test, named `"JoinpointABI "` followed
    by `condStr`, that hands all 25 programs to `expectFn` in turn through
    `Compiler.BulkCheck.bulkCheck`, which stops at the first failure and
    reports that case's label. What is checked is up to `expectFn`.
  - `suite` runs the same 25 programs through
    `TestLogic.TestPipeline.runToGlobalOpt`, which monomorphizes, inlines and
    runs the global optimizer, staging pass included, and checks that each
    gives an optimized graph with a `main` and a non-empty node array. It does
    not check which segmentation the staging pass chose.
  - Category 1 (cases 1.1 to 1.6): every branch has the same segmentation,
    one of `[2]`, `[1, 1]`, `[3]`, `[1, 1, 1]` and `[2, 1]`, and in 1.6 every
    branch returns an `Int`.
  - Category 2 (2.1 to 2.4): the branches' segmentations differ, and one of
    them belongs to more branches than any other.
  - Category 3 (3.1 to 3.4): no segmentation has more branches than another.
    In 3.1 to 3.3 the tied segmentations have different numbers of stages; in
    3.4, `[2, 1]` against `[1, 2]`, they have the same number.
  - Category 4 (4.1 to 4.6): a function value reaches the outer `case` through
    a `case` nested in a branch (4.1, 4.5, 4.6), an `if` in a branch (4.2) or a
    `let`-bound name (4.3), and in 4.4 a branch lambda's body is a `let` around
    a second lambda.
  - Category 5 (5.2 to 5.6, there is no 5.1): a lone wildcard branch (5.2),
    five lambda parameters in four segmentations (5.3), a `[2]` branch against
    a `[1, 1]` branch under a record pattern (5.4), and `case`s on a custom
    type (5.5) and on a list (5.6).

Among what is not tested: no case checks which segmentation is chosen, that a
wrapper is built, or what `testValue` evaluates to; no branch value is a kernel
function or a top-level function; no `caseFunc` is
polymorphic.

-}

import Array
import Compiler.AST.Monomorphized as Mono
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
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pRecord
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (runToGlobalOpt)


{-| A test that every program in this module gets through global optimization,
with `expectGlobalOpt` as the expectation.
-}
suite : Test
suite =
    Test.test "JoinpointABI coverage gets case branches through global optimization" <|
        \_ -> bulkCheck (testCases expectGlobalOpt)


{-| Creates an expectation that `TestLogic.TestPipeline.runToGlobalOpt`, whose
global optimizer includes `Compiler.GlobalOpt.Staging`, succeeds on `srcModule`
and gives an optimized graph with a `main` and a node array that is not empty.
-}
expectGlobalOpt : Src.Module -> Expectation
expectGlobalOpt srcModule =
    case runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                (Mono.MonoGraph data) =
                    optimizedMonoGraph
            in
            case data.main of
                Nothing ->
                    Expect.fail "Optimized graph has no main entry point"

                Just _ ->
                    if Array.isEmpty data.nodes then
                        Expect.fail "Optimized graph has no nodes"

                    else
                        Expect.pass


{-| Creates one test, named `"JoinpointABI "` followed by `condStr`, that applies
`expectFn` to every program in this module and fails with the label of the
first program it rejects.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("JoinpointABI " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the labelled cases of all five categories, in category order, each
applying `expectFn` to its program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ identicalStagingCases expectFn
        , majorityStagingCases expectFn
        , tieBreakingCases expectFn
        , nestedControlFlowCases expectFn
        , edgeCases expectFn
        ]



-- ============================================================================
-- CATEGORY 1: IDENTICAL STAGING
-- ============================================================================


{-| Returns the labelled cases of category 1, whose branches all return
functions of one segmentation, or in 1.6 all return an `Int`, each applying
`expectFn` to its program.
-}
identicalStagingCases : (Src.Module -> Expectation) -> List TestCase
identicalStagingCases expectFn =
    [ { label = "1.1 identicalFlat2", run = identicalFlat2 expectFn }
    , { label = "1.2 identicalCurried11", run = identicalCurried11 expectFn }
    , { label = "1.3 identicalFlat3", run = identicalFlat3 expectFn }
    , { label = "1.4 identicalCurried111", run = identicalCurried111 expectFn }
    , { label = "1.5 identicalMixed21", run = identicalMixed21 expectFn }
    , { label = "1.6 nonFunctionBranches", run = nonFunctionBranches expectFn }
    ]


{-| Applies `expectFn` to a program whose two branches both return a `[2]`
function, called in one application.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b -> a + b

            _ ->
                \a b -> a - b

    testValue =
        caseFunc 0 5 3

-}
identicalFlat2 : (Src.Module -> Expectation) -> (() -> Expectation)
identicalFlat2 expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose two branches both return a `[1, 1]`
function, called in two applications.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a -> \b -> a + b

            _ ->
                \a -> \b -> a - b

`testValue` is `(caseFunc 0 5) 3`, built as one call applied to the
result of another.

-}
identicalCurried11 : (Src.Module -> Expectation) -> (() -> Expectation)
identicalCurried11 expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5 ]) [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose two branches both return a `[3]`
function, called in one application.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b c -> a + b + c

            _ ->
                \a b c -> a - b - c

    testValue =
        caseFunc 0 5 3 2

-}
identicalFlat3 : (Src.Module -> Expectation) -> (() -> Expectation)
identicalFlat3 expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3, intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose two branches both return a
`[1, 1, 1]` function, called in three applications.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a -> \b -> \c -> a + b + c

            _ ->
                \a -> \b -> \c -> a - b - c

`testValue` is `((caseFunc 0 5) 3) 2`, built as three calls, each applied to
the result of the one before.

-}
identicalCurried111 : (Src.Module -> Expectation) -> (() -> Expectation)
identicalCurried111 expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (lambdaExpr [ pVar "c" ]
                                    (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                                )
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (lambdaExpr [ pVar "c" ]
                                    (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                                )
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr
                        (callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5 ])
                        [ intExpr 3 ]
                    )
                    [ intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose two branches both return a `[2, 1]`
function, called in two applications.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b -> \c -> a + b + c

            _ ->
                \a b -> \c -> a - b - c

`testValue` is `(caseFunc 0 5 3) 2`, built as one call applied to the
result of another.

-}
identicalMixed21 : (Src.Module -> Expectation) -> (() -> Expectation)
identicalMixed21 expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3 ])
                    [ intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose three branches return integer
literals, so its `case` has no function value to join.

    caseFunc : Int -> Int
    caseFunc x =
        case x of
            0 ->
                1

            1 ->
                2

            _ ->
                3

    testValue =
        caseFunc 0

-}
nonFunctionBranches : (Src.Module -> Expectation) -> (() -> Expectation)
nonFunctionBranches expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0, intExpr 1 )
                    , ( pInt 1, intExpr 2 )
                    , ( pAnything, intExpr 3 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- CATEGORY 2: DIFFERENT STAGINGS, ONE IN THE MAJORITY
-- ============================================================================


{-| Returns the labelled cases of category 2, where one segmentation has more
branches than any other, each applying `expectFn` to its program.
-}
majorityStagingCases : (Src.Module -> Expectation) -> List TestCase
majorityStagingCases expectFn =
    [ { label = "2.1 majority2Flat", run = majority2Flat expectFn }
    , { label = "2.2 majority2Curried", run = majority2Curried expectFn }
    , { label = "2.3 majority3Flat", run = majority3Flat expectFn }
    , { label = "2.4 majorityMixed", run = majorityMixed expectFn }
    ]


{-| Applies `expectFn` to a program with two `[2]` branches and one `[1, 1]`
branch, called in one application.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b -> a + b

            1 ->
                \a b -> a - b

            _ ->
                \a -> \b -> a * b

    testValue =
        caseFunc 0 5 3

-}
majority2Flat : (Src.Module -> Expectation) -> (() -> Expectation)
majority2Flat expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pInt 1
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (binopsExpr [ ( varExpr "a", "*" ) ] (varExpr "b"))
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with one `[2]` branch and two `[1, 1]`
branches, called in two applications.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b -> a + b

            1 ->
                \a -> \b -> a - b

            _ ->
                \a -> \b -> a * b

`testValue` is `(caseFunc 0 5) 3`, built as one call applied to the
result of another.

-}
majority2Curried : (Src.Module -> Expectation) -> (() -> Expectation)
majority2Curried expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pInt 1
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (binopsExpr [ ( varExpr "a", "*" ) ] (varExpr "b"))
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5 ]) [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with three `[3]` branches and one
`[1, 1, 1]` branch, called in one application.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b c -> a + b + c

            1 ->
                \a b c -> a - b - c

            2 ->
                \a b c -> a * b * c

            _ ->
                \a -> \b -> \c -> a + b - c

    testValue =
        caseFunc 0 5 3 2

-}
majority3Flat : (Src.Module -> Expectation) -> (() -> Expectation)
majority3Flat expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                      )
                    , ( pInt 1
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                      )
                    , ( pInt 2
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "*" ), ( varExpr "b", "*" ) ] (varExpr "c"))
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (lambdaExpr [ pVar "c" ]
                                    (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                                )
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3, intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with two `[2, 1]` branches, one `[1, 2]`
branch and one `[3]` branch, called in two applications.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b -> \c -> a + b + c

            1 ->
                \a b -> \c -> a - b - c

            2 ->
                \a -> \b c -> a * b * c

            _ ->
                \a b c -> a + b - c

`testValue` is `(caseFunc 0 5 3) 2`, built as one call applied to the
result of another.

-}
majorityMixed : (Src.Module -> Expectation) -> (() -> Expectation)
majorityMixed expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                            )
                      )
                    , ( pInt 1
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                            )
                      )
                    , ( pInt 2
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b", pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "*" ), ( varExpr "b", "*" ) ] (varExpr "c"))
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3 ])
                    [ intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- CATEGORY 3: TIED STAGINGS
-- ============================================================================


{-| Returns the labelled cases of category 3, where no segmentation has more
branches than another, each applying `expectFn` to its program.
-}
tieBreakingCases : (Src.Module -> Expectation) -> List TestCase
tieBreakingCases expectFn =
    [ { label = "3.1 tieBreakBinary", run = tieBreakBinary expectFn }
    , { label = "3.2 tieBreakTernary", run = tieBreakTernary expectFn }
    , { label = "3.3 tieBreakQuaternary", run = tieBreakQuaternary expectFn }
    , { label = "3.4 tieEqualDepth", run = tieEqualDepth expectFn }
    ]


{-| Applies `expectFn` to a program with one `[2]` branch and one `[1, 1]`
branch, called in one application.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc n =
        case n of
            0 ->
                \a x -> a + x

            _ ->
                \a -> \x -> a - x

    testValue =
        caseFunc 0 5 3

-}
tieBreakBinary : (Src.Module -> Expectation) -> (() -> Expectation)
tieBreakBinary expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "n" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "x" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "x"))
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "x" ]
                                (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "x"))
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with one branch each of `[3]`, `[2, 1]` and
`[1, 1, 1]`, called in one application.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b c -> a + b + c

            1 ->
                \a b -> \c -> a - b - c

            _ ->
                \a -> \b -> \c -> a * b * c

    testValue =
        caseFunc 0 5 3 2

-}
tieBreakTernary : (Src.Module -> Expectation) -> (() -> Expectation)
tieBreakTernary expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                      )
                    , ( pInt 1
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (lambdaExpr [ pVar "c" ]
                                    (binopsExpr [ ( varExpr "a", "*" ), ( varExpr "b", "*" ) ] (varExpr "c"))
                                )
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3, intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with one branch each of `[4]`, `[2, 2]` and
`[1, 1, 1, 1]`, called in one application.

    caseFunc : Int -> Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b c d -> a + b + c + d

            1 ->
                \a b -> \c d -> a - b - c - d

            _ ->
                \a -> \b -> \c -> \d -> a * b * c * d

    testValue =
        caseFunc 0 5 3 2 1

-}
tieBreakQuaternary : (Src.Module -> Expectation) -> (() -> Expectation)
tieBreakQuaternary expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" [])
                                (tLambda (tType "Int" []) (tType "Int" []))
                            )
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c", pVar "d" ]
                            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ), ( varExpr "c", "+" ) ] (varExpr "d"))
                      )
                    , ( pInt 1
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c", pVar "d" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ), ( varExpr "c", "-" ) ] (varExpr "d"))
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (lambdaExpr [ pVar "c" ]
                                    (lambdaExpr [ pVar "d" ]
                                        (binopsExpr [ ( varExpr "a", "*" ), ( varExpr "b", "*" ), ( varExpr "c", "*" ) ] (varExpr "d"))
                                    )
                                )
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3, intExpr 2, intExpr 1 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with one `[2, 1]` branch and one `[1, 2]`
branch, both of two stages, called in two applications.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc n =
        case n of
            0 ->
                \a b -> \c -> a + b + c

            _ ->
                \a -> \b c -> a - b - c

`testValue` is `(caseFunc 0 5 3) 2`, built as one call applied to the
result of another.

-}
tieEqualDepth : (Src.Module -> Expectation) -> (() -> Expectation)
tieEqualDepth expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "n" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b", pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5, intExpr 3 ])
                    [ intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- CATEGORY 4: NESTED CONTROL FLOW
-- ============================================================================


{-| Returns the labelled cases of category 4, where function values pass through
nested `case` and `let` expressions, each applying `expectFn` to its program.
-}
nestedControlFlowCases : (Src.Module -> Expectation) -> List TestCase
nestedControlFlowCases expectFn =
    [ { label = "4.1 nestedCaseInBranch", run = nestedCaseInBranch expectFn }
    , { label = "4.2 ifInCaseBranch", run = ifInCaseBranch expectFn }
    , { label = "4.3 letFunctionInBranch", run = letFunctionInBranch expectFn }
    , { label = "4.4 letSeparatedStaging", run = letSeparatedStaging expectFn }
    , { label = "4.5 deeplyNestedControl", run = deeplyNestedControl expectFn }
    , { label = "4.6 caseInBothBranches", run = caseInBothBranches expectFn }
    ]


{-| Applies `expectFn` to a program whose outer `case` has an inner `case` as
one branch. Every function value is a `[1]` lambda.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc x y =
        case x of
            0 ->
                case y of
                    0 ->
                        \a -> a + 1

                    _ ->
                        \a -> a - 1

            _ ->
                \a -> a * 2

    testValue =
        caseFunc 0 0 5

-}
nestedCaseInBranch : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCaseInBranch expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , caseExpr (varExpr "y")
                            [ ( pInt 0
                              , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (intExpr 1))
                              )
                            , ( pAnything
                              , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "-" ) ] (intExpr 1))
                              )
                            ]
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 2))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 0, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose outer `case` has an `if` as one
branch, so two of the function values meet at the `if` before the `case`. Every
function value is a `[1]` lambda.

    caseFunc : Int -> Bool -> Int -> Int
    caseFunc n flag =
        case n of
            0 ->
                if flag then
                    \a -> a + 1

                else
                    \a -> a - 1

            _ ->
                \a -> a * 2

    testValue =
        caseFunc 0 True 5

-}
ifInCaseBranch : (Src.Module -> Expectation) -> (() -> Expectation)
ifInCaseBranch expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "n", pVar "flag" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Bool" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0
                      , ifExpr (varExpr "flag")
                            (lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (intExpr 1)))
                            (lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "-" ) ] (intExpr 1)))
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 2))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, boolExpr True, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program where one branch returns a `let`-bound lambda
by name and the other returns a lambda directly, both `[1]`.

    caseFunc : Int -> Int -> Int
    caseFunc n =
        case n of
            0 ->
                let
                    f =
                        \a -> a + 1
                in
                f

            _ ->
                \a -> a * 2

    testValue =
        caseFunc 0 5

-}
letFunctionInBranch : (Src.Module -> Expectation) -> (() -> Expectation)
letFunctionInBranch expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "n" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0
                      , letExpr
                            [ define "f" [] (lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (intExpr 1)))
                            ]
                            (varExpr "f")
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 2))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program where a `let` sits between the two lambda
layers of one branch, against a single two-parameter lambda in the other. The
`let` reads `caseFunc`'s second parameter `k`, so the inner lambda captures a
value computed from it.

    caseFunc : Int -> Int -> Int -> Int -> Int
    caseFunc n k =
        case n of
            0 ->
                \a ->
                    let
                        y =
                            a + k
                    in
                    \z -> y + z

            _ ->
                \a z -> a + z

`testValue` is `(caseFunc 0 10 5) 3`, built as one call applied to the
result of another.

-}
letSeparatedStaging : (Src.Module -> Expectation) -> (() -> Expectation)
letSeparatedStaging expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "n", pVar "k" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a" ]
                            (letExpr
                                [ define "y" [] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "k"))
                                ]
                                (lambdaExpr [ pVar "z" ]
                                    (binopsExpr [ ( varExpr "y", "+" ) ] (varExpr "z"))
                                )
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a", pVar "z" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "z"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 10, intExpr 5 ]) [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program nesting a `case` in a `case` branch, with a
`let` around the lambda in the first branch of the inner `case`. Every function
value is a `[1]` lambda.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc x m =
        case x of
            0 ->
                case m of
                    0 ->
                        let
                            k =
                                10
                        in
                        \a -> a + k

                    _ ->
                        \a -> a - 5

            _ ->
                \a -> a * 2

    testValue =
        caseFunc 0 0 5

-}
deeplyNestedControl : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedControl expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x", pVar "m" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , caseExpr (varExpr "m")
                            [ ( pInt 0
                              , letExpr
                                    [ define "k" [] (intExpr 10)
                                    ]
                                    (lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "k")))
                              )
                            , ( pAnything
                              , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "-" ) ] (intExpr 5))
                              )
                            ]
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 2))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 0, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program where both branches of the outer `case` are
inner `case`s on the second parameter. Every function value is a `[1]` lambda.

    caseFunc : Int -> Int -> Int -> Int
    caseFunc x y =
        case x of
            0 ->
                case y of
                    0 ->
                        \a -> a + 1

                    _ ->
                        \a -> a + 2

            _ ->
                case y of
                    0 ->
                        \a -> a - 1

                    _ ->
                        \a -> a - 2

    testValue =
        caseFunc 0 1 5

-}
caseInBothBranches : (Src.Module -> Expectation) -> (() -> Expectation)
caseInBothBranches expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , caseExpr (varExpr "y")
                            [ ( pInt 0
                              , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (intExpr 1))
                              )
                            , ( pAnything
                              , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (intExpr 2))
                              )
                            ]
                      )
                    , ( pAnything
                      , caseExpr (varExpr "y")
                            [ ( pInt 0
                              , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "-" ) ] (intExpr 1))
                              )
                            , ( pAnything
                              , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "-" ) ] (intExpr 2))
                              )
                            ]
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 1, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- CATEGORY 5: EDGE CASES
-- ============================================================================


{-| Returns the labelled cases of category 5, the edge cases, each applying
`expectFn` to its program.
-}
edgeCases : (Src.Module -> Expectation) -> List TestCase
edgeCases expectFn =
    [ { label = "5.2 wildcardOnlyCase", run = wildcardOnlyCase expectFn }
    , { label = "5.3 highArityFunction", run = highArityFunction expectFn }
    , { label = "5.4 recordPatternBranches", run = recordPatternBranches expectFn }
    , { label = "5.5 customTypeBranches", run = customTypeBranches expectFn }
    , { label = "5.6 listPatternBranches", run = listPatternBranches expectFn }
    ]


{-| Applies `expectFn` to a program whose `case` has a single wildcard branch,
returning a `[1]` lambda.

    caseFunc : Int -> Int -> Int
    caseFunc x =
        case x of
            _ ->
                \a -> a + 1

    testValue =
        caseFunc 42 5

-}
wildcardOnlyCase : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardOnlyCase expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "x")
                    [ ( pAnything
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (intExpr 1))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 42, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose branches return five-parameter
functions, one branch each of `[5]`, `[3, 2]`, `[2, 2, 1]` and
`[1, 1, 1, 1, 1]`, called in one application of six arguments.

    caseFunc : Int -> Int -> Int -> Int -> Int -> Int -> Int
    caseFunc x =
        case x of
            0 ->
                \a b c d e -> a + b + c + d + e

            1 ->
                \a b c -> \d e -> a - b - c - d - e

            2 ->
                \a b -> \c d -> \e -> a * b * c * d * e

            _ ->
                \a -> \b -> \c -> \d -> \e -> a + b - c * d + e

    testValue =
        caseFunc 0 1 2 3 4 5

-}
highArityFunction : (Src.Module -> Expectation) -> (() -> Expectation)
highArityFunction expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" [])
                                (tLambda (tType "Int" [])
                                    (tLambda (tType "Int" []) (tType "Int" []))
                                )
                            )
                        )
                    )
            , body =
                caseExpr (varExpr "x")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c", pVar "d", pVar "e" ]
                            (binopsExpr
                                [ ( varExpr "a", "+" )
                                , ( varExpr "b", "+" )
                                , ( varExpr "c", "+" )
                                , ( varExpr "d", "+" )
                                ]
                                (varExpr "e")
                            )
                      )
                    , ( pInt 1
                      , lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (lambdaExpr [ pVar "d", pVar "e" ]
                                (binopsExpr
                                    [ ( varExpr "a", "-" )
                                    , ( varExpr "b", "-" )
                                    , ( varExpr "c", "-" )
                                    , ( varExpr "d", "-" )
                                    ]
                                    (varExpr "e")
                                )
                            )
                      )
                    , ( pInt 2
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c", pVar "d" ]
                                (lambdaExpr [ pVar "e" ]
                                    (binopsExpr
                                        [ ( varExpr "a", "*" )
                                        , ( varExpr "b", "*" )
                                        , ( varExpr "c", "*" )
                                        , ( varExpr "d", "*" )
                                        ]
                                        (varExpr "e")
                                    )
                                )
                            )
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b" ]
                                (lambdaExpr [ pVar "c" ]
                                    (lambdaExpr [ pVar "d" ]
                                        (lambdaExpr [ pVar "e" ]
                                            (binopsExpr
                                                [ ( varExpr "a", "+" )
                                                , ( varExpr "b", "-" )
                                                , ( varExpr "c", "*" )
                                                , ( varExpr "d", "+" )
                                                ]
                                                (varExpr "e")
                                            )
                                        )
                                    )
                                )
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ intExpr 0, intExpr 1, intExpr 2, intExpr 3, intExpr 4, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `case` destructures a record with a
record pattern and then cases on one of its fields, with one `[2]` branch and one
`[1, 1]` branch, both capturing the other field. It is called in one
application.

    caseFunc : { tag : Int, k : Int } -> Int -> Int -> Int
    caseFunc r =
        case r of
            { tag, k } ->
                case tag of
                    0 ->
                        \x y -> x + y + k

                    _ ->
                        \x -> \y -> x - y - k

    testValue =
        caseFunc { tag = 0, k = 1 } 5 3

-}
recordPatternBranches : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternBranches expectFn _ =
    let
        recordType =
            tRecord [ ( "tag", tType "Int" [] ), ( "k", tType "Int" [] ) ]

        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "r" ]
            , tipe =
                tLambda recordType
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "r")
                    [ ( pRecord [ "tag", "k" ]
                      , caseExpr (varExpr "tag")
                            [ ( pInt 0
                              , lambdaExpr [ pVar "x", pVar "y" ]
                                    (binopsExpr [ ( varExpr "x", "+" ), ( varExpr "y", "+" ) ] (varExpr "k"))
                              )
                            , ( pAnything
                              , lambdaExpr [ pVar "x" ]
                                    (lambdaExpr [ pVar "y" ]
                                        (binopsExpr [ ( varExpr "x", "-" ), ( varExpr "y", "-" ) ] (varExpr "k"))
                                    )
                              )
                            ]
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "caseFunc")
                    [ recordExpr [ ( "tag", intExpr 0 ), ( "k", intExpr 1 ) ]
                    , intExpr 5
                    , intExpr 3
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with a `case` on a locally declared union,
whose branches return `[1]` lambdas, one capturing the constructor's payload.

    type MaybeInt
        = JustInt Int
        | NothingInt

    caseFunc : MaybeInt -> Int -> Int
    caseFunc mx =
        case mx of
            JustInt n ->
                \a -> a + n

            NothingInt ->
                \a -> a * 0

    testValue =
        caseFunc (JustInt 10) 5

-}
customTypeBranches : (Src.Module -> Expectation) -> (() -> Expectation)
customTypeBranches expectFn _ =
    let
        maybeIntDef : UnionDef
        maybeIntDef =
            { name = "MaybeInt"
            , args = []
            , ctors =
                [ { name = "JustInt", args = [ tType "Int" [] ] }
                , { name = "NothingInt", args = [] }
                ]
            }

        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "mx" ]
            , tipe =
                tLambda (tType "MaybeInt" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "JustInt" [ pVar "n" ]
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "n"))
                      )
                    , ( pCtor "NothingInt" []
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 0))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ callExpr (ctorExpr "JustInt") [ intExpr 10 ], intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                [ maybeIntDef ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program with a `case` on a list, whose branches
return `[1]` lambdas, the cons branch capturing the head.

    caseFunc : List Int -> Int -> Int
    caseFunc xs =
        case xs of
            [] ->
                \a -> a

            h :: t ->
                \a -> a + h

    testValue =
        caseFunc [ 10, 20 ] 5

-}
listPatternBranches : (Src.Module -> Expectation) -> (() -> Expectation)
listPatternBranches expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tType "Int" [] ])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList []
                      , lambdaExpr [ pVar "a" ] (varExpr "a")
                      )
                    , ( pCons (pVar "h") (pVar "t")
                      , lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "h"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "caseFunc") [ listExpr [ intExpr 10, intExpr 20 ], intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseFuncDef, testValueDef ]
                []
                []
    in
    expectFn modul
