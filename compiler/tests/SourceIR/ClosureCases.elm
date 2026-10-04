module SourceIR.ClosureCases exposing (expectSuite, suite)

{-| Programs in which a function refers to local variables bound outside it, so
that the compiler's handling of closures meets a range of capture shapes.

A closure is a function value together with the variables it refers to but does
not bind, its _captures_. During monomorphization `Compiler.Monomorphize.Closure`
finds each closure's free variables and a type for each one. A variable it
misses is not carried by the closure, and one it finds but cannot type makes
`computeClosureCaptures` crash. The shapes below vary where a captured variable
is referenced, how deeply closures nest, and what type a capture has.

This module only builds programs; what is checked is decided by the
expectation function each program is given. `expectSuite` gives every program
to the caller's `expectFn`, and `suite` gives every program to
`TestLogic.TestPipeline.expectMonomorphization`. Either way the 28 cases run as
one test through `Compiler.BulkCheck.bulkCheck`, which reports the first
failing case by its label and does not run the cases after it. A case that
crashes, as `computeClosureCaptures` does, ends the test without its label
being reported.

Each program is a module named `Test`, built with
`makeModuleWithTypedDefsUnionsAliases` and so importing that builder's standard
set. Every top-level definition carries an annotation with no type variable
in it, mostly in terms of `Int`. Each program defines `testValue`, which uses
the function under test on fixed arguments. Programs that match on `Maybe`
declare their own `Maybe` type.

The cases, by group:

  - Simple closures: a returned lambda capturing one argument
    (`makeAdder`) or two (`makeCombiner`); a lambda bound in a `let` and
    capturing the enclosing argument; a returned lambda passed to a function
    that applies it twice; and a lambda capturing an argument and applied where
    it is written.
  - Nested closures: lambdas nested two and three deep, the innermost
    combining the variables bound at every enclosing level; and a let-bound
    lambda whose own let-bound lambda captures both the outer lambda's
    parameter and the function's argument.
  - Closures in case expressions: a lambda in a `Just` branch capturing the
    pattern variable; three lambdas chosen by an `if` chain inside a
    single-branch case, none of which captures anything; a lambda in a `::`
    branch capturing the list head; and lambdas in both branches of a `Maybe`
    case, one capturing the pattern variable and the other the function's
    other argument.
  - Captured types: a record, whose fields the lambda reads; the two
    components of a tuple, bound by a case pattern; a list head; and an `Int`
    argument captured together with a list head.
  - Recursion: a capturing lambda passed to a recursive `mapList`; a
    recursive let-bound `go` that refers only to its own parameters and
    itself, capturing nothing; and a recursive let-bound `go` that captures
    the enclosing `factor`.
  - Captures of different representations at one call site: a let-bound `f`
    chosen by `if True` between two partial applications, then applied to 3.
    One pair captures an `Int` against a `Float`, the other a value of a
    declared custom type against an `Int`. At closure boundaries the MLIR back
    end gives an `Int` the type `i64`, a `Float` `f64`, and a custom type
    `!eco.value`.
  - A capture referenced only by destructuring: inside the lambda, the
    captured variable is the scrutinee of a case that binds its contents, of
    the single-constructor type `Wrapper Int` in one case and `Maybe String`
    in the other. After monomorphization such a variable appears as the root
    of the case and of a destructuring path, not as a local variable
    reference.
  - A capture referenced only as a case scrutinee: a let-bound function
    whose sole use of a captured variable is as the scrutinee of a case. The
    scrutinee is a declared enumeration, an `Int` matched against a literal,
    and a `Bool`; in the fourth case it is used by a function defined inside
    another let-bound function, two levels below the argument it refers to.

Among what is not tested: a polymorphic top-level function, a captured
variable of a function type, mutually recursive let-bound closures, and
captures of `Char`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pCtor
        , pInt
        , pList
        , pTuple
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| A test that gives every program here to
`TestLogic.TestPipeline.expectMonomorphization`.
-}
suite : Test
suite =
    Test.test "Closure handling coverage monomorphizes closures" <|
        \_ -> bulkCheck (testCases expectMonomorphization)


{-| Creates one test that gives every program here to `expectFn`, named
"Closure handling " followed by `condStr`.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Closure handling " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of every group, in the order the module docstring lists
the groups, each checked with `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ simpleClosureCases expectFn
        , nestedClosureCases expectFn
        , closureInCaseCases expectFn
        , closureCapturingTypesCases expectFn
        , closureWithRecursionCases expectFn
        , heteroClosureCases expectFn
        , closureDestructCaptureCases expectFn
        , closureCaseScrutineeCases expectFn
        ]



-- ============================================================================
-- SIMPLE CLOSURE TESTS
-- ============================================================================


{-| Returns the simple-closure cases, each checked with `expectFn`.
-}
simpleClosureCases : (Src.Module -> Expectation) -> List TestCase
simpleClosureCases expectFn =
    [ { label = "Closure over single local", run = closureOverSingleLocal expectFn }
    , { label = "Closure over two locals", run = closureOverTwoLocals expectFn }
    , { label = "Closure in let binding", run = closureInLetBinding expectFn }
    , { label = "Closure as return value", run = closureAsReturnValue expectFn }
    , { label = "Closure applied immediately", run = closureAppliedImmediately expectFn }
    ]


{-| Builds a program in which `makeAdder x` returns a lambda capturing `x`,
and gives it to `expectFn`.
-}
closureOverSingleLocal : (Src.Module -> Expectation) -> (() -> Expectation)
closureOverSingleLocal expectFn _ =
    let
        -- makeAdder : Int -> (Int -> Int)
        -- makeAdder x = \y -> x + y
        makeAdderDef : TypedDef
        makeAdderDef =
            { name = "makeAdder"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                lambdaExpr [ pVar "y" ]
                    (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (callExpr (varExpr "makeAdder") [ intExpr 5 ]) [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ makeAdderDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which `makeCombiner a b` returns a lambda capturing
both `a` and `b`, and gives it to `expectFn`.
-}
closureOverTwoLocals : (Src.Module -> Expectation) -> (() -> Expectation)
closureOverTwoLocals expectFn _ =
    let
        -- makeCombiner : Int -> Int -> (Int -> Int)
        -- makeCombiner a b = \x -> a * x + b
        makeCombinerDef : TypedDef
        makeCombinerDef =
            { name = "makeCombiner"
            , args = [ pVar "a", pVar "b" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                lambdaExpr [ pVar "x" ]
                    (binopsExpr
                        [ ( varExpr "a", "*" )
                        , ( varExpr "x", "+" )
                        ]
                        (varExpr "b")
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (callExpr (varExpr "makeCombiner") [ intExpr 2, intExpr 3 ]) [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ makeCombinerDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which a lambda bound by a `let` captures the enclosing
function's argument and is called inside that `let`, and gives it to
`expectFn`.
-}
closureInLetBinding : (Src.Module -> Expectation) -> (() -> Expectation)
closureInLetBinding expectFn _ =
    let
        -- letClosure : Int -> Int
        -- letClosure n =
        --     let f = \x -> x + n
        --     in f 10
        letClosureDef : TypedDef
        letClosureDef =
            { name = "letClosure"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                letExpr
                    [ define "f" [] (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))) ]
                    (callExpr (varExpr "f") [ intExpr 10 ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "letClosure") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ letClosureDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which the lambda returned by `makeMultiplier 2`,
capturing its argument, is passed to `applyTwice`, and gives it to `expectFn`.
-}
closureAsReturnValue : (Src.Module -> Expectation) -> (() -> Expectation)
closureAsReturnValue expectFn _ =
    let
        -- makeMultiplier : Int -> (Int -> Int)
        -- makeMultiplier factor = \x -> x * factor
        makeMultiplierDef : TypedDef
        makeMultiplierDef =
            { name = "makeMultiplier"
            , args = [ pVar "factor" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                lambdaExpr [ pVar "x" ]
                    (binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "factor"))
            }

        -- applyTwice : (Int -> Int) -> Int -> Int
        -- applyTwice f x = f (f x)
        applyTwiceDef : TypedDef
        applyTwiceDef =
            { name = "applyTwice"
            , args = [ pVar "f", pVar "x" ]
            , tipe =
                tLambda (tLambda (tType "Int" []) (tType "Int" []))
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (varExpr "f")
                    [ callExpr (varExpr "f") [ varExpr "x" ] ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "applyTwice")
                    [ callExpr (varExpr "makeMultiplier") [ intExpr 2 ]
                    , intExpr 3
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ makeMultiplierDef, applyTwiceDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which a lambda capturing the enclosing argument is
applied where it is written, and gives it to `expectFn`.
-}
closureAppliedImmediately : (Src.Module -> Expectation) -> (() -> Expectation)
closureAppliedImmediately expectFn _ =
    let
        -- immediate : Int -> Int
        -- immediate n = (\x -> x + n) 10
        immediateDef : TypedDef
        immediateDef =
            { name = "immediate"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                callExpr
                    (lambdaExpr [ pVar "x" ]
                        (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))
                    )
                    [ intExpr 10 ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "immediate") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ immediateDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED CLOSURE TESTS
-- ============================================================================


{-| Returns the nested-closure cases, each checked with `expectFn`.
-}
nestedClosureCases : (Src.Module -> Expectation) -> List TestCase
nestedClosureCases expectFn =
    [ { label = "Double nested closure", run = doubleNestedClosure expectFn }
    , { label = "Closure returning closure", run = closureReturningClosure expectFn }
    , { label = "Nested let closures", run = nestedLetClosures expectFn }
    , { label = "Triple nested closure", run = tripleNestedClosure expectFn }
    ]


{-| Builds a program in which a function returns a lambda that returns a
second lambda, the second capturing the function's argument and the first
lambda's parameter, and gives it to `expectFn`.
-}
doubleNestedClosure : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNestedClosure expectFn _ =
    let
        -- makeNestedAdder : Int -> (Int -> (Int -> Int))
        -- makeNestedAdder x = \y -> \z -> x + y + z
        makeNestedAdderDef : TypedDef
        makeNestedAdderDef =
            { name = "makeNestedAdder"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                lambdaExpr [ pVar "y" ]
                    (lambdaExpr [ pVar "z" ]
                        (binopsExpr
                            [ ( varExpr "x", "+" )
                            , ( varExpr "y", "+" )
                            ]
                            (varExpr "z")
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr
                        (callExpr (varExpr "makeNestedAdder") [ intExpr 1 ])
                        [ intExpr 2 ]
                    )
                    [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ makeNestedAdderDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which `makeClosureFactory base` returns a lambda that
returns a second lambda, the second capturing `base` and the first lambda's
`multiplier`, and gives it to `expectFn`.
-}
closureReturningClosure : (Src.Module -> Expectation) -> (() -> Expectation)
closureReturningClosure expectFn _ =
    let
        -- makeClosureFactory : Int -> (Int -> (Int -> Int))
        -- makeClosureFactory base = \multiplier -> \x -> base + multiplier * x
        makeClosureFactoryDef : TypedDef
        makeClosureFactoryDef =
            { name = "makeClosureFactory"
            , args = [ pVar "base" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                lambdaExpr [ pVar "multiplier" ]
                    (lambdaExpr [ pVar "x" ]
                        (binopsExpr
                            [ ( varExpr "base", "+" )
                            , ( varExpr "multiplier", "*" )
                            ]
                            (varExpr "x")
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr
                        (callExpr (varExpr "makeClosureFactory") [ intExpr 10 ])
                        [ intExpr 2 ]
                    )
                    [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ makeClosureFactoryDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which a let-bound lambda `outer` defines its own
let-bound lambda `inner`, which captures `outer`'s parameter and the enclosing
function's argument, and gives it to `expectFn`.
-}
nestedLetClosures : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLetClosures expectFn _ =
    let
        -- nestedLets : Int -> Int
        -- nestedLets n =
        --     let outer = \x ->
        --             let inner = \y -> x + y + n
        --             in inner 10
        --     in outer 5
        nestedLetsDef : TypedDef
        nestedLetsDef =
            { name = "nestedLets"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                letExpr
                    [ define "outer"
                        []
                        (lambdaExpr [ pVar "x" ]
                            (letExpr
                                [ define "inner"
                                    []
                                    (lambdaExpr [ pVar "y" ]
                                        (binopsExpr
                                            [ ( varExpr "x", "+" )
                                            , ( varExpr "y", "+" )
                                            ]
                                            (varExpr "n")
                                        )
                                    )
                                ]
                                (callExpr (varExpr "inner") [ intExpr 10 ])
                            )
                        )
                    ]
                    (callExpr (varExpr "outer") [ intExpr 5 ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "nestedLets") [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ nestedLetsDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which lambdas are nested three deep below a function,
the innermost capturing the function's argument and both enclosing lambdas'
parameters, and gives it to `expectFn`.
-}
tripleNestedClosure : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedClosure expectFn _ =
    let
        -- tripleNested : Int -> Int -> Int -> Int -> Int
        -- tripleNested a = \b -> \c -> \d -> a + b + c + d
        tripleNestedDef : TypedDef
        tripleNestedDef =
            { name = "tripleNested"
            , args = [ pVar "a" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tLambda (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                lambdaExpr [ pVar "b" ]
                    (lambdaExpr [ pVar "c" ]
                        (lambdaExpr [ pVar "d" ]
                            (binopsExpr
                                [ ( varExpr "a", "+" )
                                , ( varExpr "b", "+" )
                                , ( varExpr "c", "+" )
                                ]
                                (varExpr "d")
                            )
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr
                        (callExpr
                            (callExpr (varExpr "tripleNested") [ intExpr 1 ])
                            [ intExpr 2 ]
                        )
                        [ intExpr 3 ]
                    )
                    [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ tripleNestedDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- CLOSURE IN CASE TESTS
-- ============================================================================


{-| Returns the cases with closures inside case expressions, each checked with
`expectFn`.
-}
closureInCaseCases : (Src.Module -> Expectation) -> List TestCase
closureInCaseCases expectFn =
    [ { label = "Closure in case branch", run = closureInCaseBranch expectFn }
    , { label = "Different closures per branch", run = differentClosuresPerBranch expectFn }
    , { label = "Closure capturing scrutinee", run = closureCapturingScrutinee expectFn }
    , { label = "Closure in Maybe case", run = closureInMaybeCase expectFn }
    ]


{-| Builds a program in which the `Just` branch of a case on a `Maybe Int`
returns a lambda capturing the pattern variable, while the `Nothing` branch
returns one capturing nothing, and gives it to `expectFn`. The program declares
its own `Maybe`.
-}
closureInCaseBranch : (Src.Module -> Expectation) -> (() -> Expectation)
closureInCaseBranch expectFn _ =
    let
        maybeUnion : UnionDef
        maybeUnion =
            { name = "Maybe"
            , args = [ "a" ]
            , ctors =
                [ { name = "Just", args = [ tVar "a" ] }
                , { name = "Nothing", args = [] }
                ]
            }

        -- caseClosure : Maybe Int -> (Int -> Int)
        -- caseClosure m =
        --     case m of
        --         Just n -> \x -> x + n
        --         Nothing -> \x -> x
        caseClosureDef : TypedDef
        caseClosureDef =
            { name = "caseClosure"
            , args = [ pVar "m" ]
            , tipe =
                tLambda (tType "Maybe" [ tType "Int" [] ])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Just" [ pVar "n" ]
                      , lambdaExpr [ pVar "x" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))
                      )
                    , ( pCtor "Nothing" []
                      , lambdaExpr [ pVar "x" ] (varExpr "x")
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
                    (callExpr (varExpr "caseClosure")
                        [ callExpr (ctorExpr "Just") [ intExpr 5 ] ]
                    )
                    [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ caseClosureDef, testValueDef ]
                [ maybeUnion ]
                []
    in
    expectFn modul


{-| Builds a program in which a case with a single variable branch chooses,
through an `if` chain on that variable, one of three lambdas, and gives it to
`expectFn`. None of the three lambdas captures anything.
-}
differentClosuresPerBranch : (Src.Module -> Expectation) -> (() -> Expectation)
differentClosuresPerBranch expectFn _ =
    let
        -- opClosure : Int -> (Int -> Int)
        -- opClosure op =
        --     case op of
        --         n ->
        --             if n == 0 then \x -> x + 1
        --             else if n == 1 then \x -> x * 2
        --             else \x -> x
        opClosureDef : TypedDef
        opClosureDef =
            { name = "opClosure"
            , args = [ pVar "op" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "op")
                    [ ( pVar "n"
                      , ifExpr
                            (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                            (lambdaExpr [ pVar "x" ]
                                (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                            )
                            (ifExpr
                                (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 1))
                                (lambdaExpr [ pVar "x" ]
                                    (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                                )
                                (lambdaExpr [ pVar "x" ] (varExpr "x"))
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
                    (callExpr (varExpr "opClosure") [ intExpr 1 ])
                    [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ opClosureDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which the `::` branch of a case on a list returns a
lambda capturing the head bound by the pattern, and gives it to `expectFn`.
The lambda captures the head, not the scrutinee itself.
-}
closureCapturingScrutinee : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingScrutinee expectFn _ =
    let
        -- captureScrutinee : List Int -> (Int -> Int)
        -- captureScrutinee xs =
        --     case xs of
        --         [] -> \x -> x
        --         h :: _ -> \x -> x + h
        -- (the tail is built as pVar "_", a variable named `_`)
        captureScrutineeDef : TypedDef
        captureScrutineeDef =
            { name = "captureScrutinee"
            , args = [ pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tType "Int" [] ])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList []
                      , lambdaExpr [ pVar "x" ] (varExpr "x")
                      )
                    , ( pCons (pVar "h") (pVar "_")
                      , lambdaExpr [ pVar "x" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "h"))
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
                    (callExpr (varExpr "captureScrutinee")
                        [ listExpr [ intExpr 5, intExpr 6 ] ]
                    )
                    [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ captureScrutineeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which both branches of a case on a `Maybe Int` return
a capturing lambda, and gives it to `expectFn`. The `Just` branch's lambda
captures the pattern variable and the `Nothing` branch's captures the
function's other argument. The program declares its own `Maybe`, and
`testValue` passes `Nothing`.
-}
closureInMaybeCase : (Src.Module -> Expectation) -> (() -> Expectation)
closureInMaybeCase expectFn _ =
    let
        maybeUnion : UnionDef
        maybeUnion =
            { name = "Maybe"
            , args = [ "a" ]
            , ctors =
                [ { name = "Just", args = [ tVar "a" ] }
                , { name = "Nothing", args = [] }
                ]
            }

        -- withDefault : Int -> Maybe Int -> (Int -> Int)
        -- withDefault default m =
        --     case m of
        --         Just val -> \x -> x + val
        --         Nothing -> \x -> x + default
        withDefaultDef : TypedDef
        withDefaultDef =
            { name = "withDefault"
            , args = [ pVar "default", pVar "m" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Maybe" [ tType "Int" [] ])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Just" [ pVar "val" ]
                      , lambdaExpr [ pVar "x" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "val"))
                      )
                    , ( pCtor "Nothing" []
                      , lambdaExpr [ pVar "x" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "default"))
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
                    (callExpr (varExpr "withDefault")
                        [ intExpr 0
                        , ctorExpr "Nothing"
                        ]
                    )
                    [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ withDefaultDef, testValueDef ]
                [ maybeUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- CLOSURE CAPTURING TYPES TESTS
-- ============================================================================


{-| Returns the cases that vary the type of what is captured, each checked
with `expectFn`.
-}
closureCapturingTypesCases : (Src.Module -> Expectation) -> List TestCase
closureCapturingTypesCases expectFn =
    [ { label = "Closure capturing record", run = closureCapturingRecord expectFn }
    , { label = "Closure capturing tuple", run = closureCapturingTuple expectFn }
    , { label = "Closure capturing list head", run = closureCapturingListHead expectFn }
    , { label = "Closure capturing multiple types", run = closureCapturingMultipleTypes expectFn }
    ]


{-| Builds a program in which a lambda captures a record argument and reads
two of its fields, and gives it to `expectFn`.
-}
closureCapturingRecord : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingRecord expectFn _ =
    let
        -- closureWithRecord : { x : Int, y : Int } -> (Int -> Int)
        -- closureWithRecord rec = \n -> rec.x + rec.y + n
        closureWithRecordDef : TypedDef
        closureWithRecordDef =
            { name = "closureWithRecord"
            , args = [ pVar "rec" ]
            , tipe =
                tLambda (tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                lambdaExpr [ pVar "n" ]
                    (binopsExpr
                        [ ( accessExpr (varExpr "rec") "x", "+" )
                        , ( accessExpr (varExpr "rec") "y", "+" )
                        ]
                        (varExpr "n")
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr (varExpr "closureWithRecord")
                        [ recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ] ]
                    )
                    [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ closureWithRecordDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which a case destructures a tuple argument and a
lambda captures both components, and gives it to `expectFn`. The tuple itself
is not referenced inside the lambda.
-}
closureCapturingTuple : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingTuple expectFn _ =
    let
        -- closureWithTuple : (Int, Int) -> (Int -> Int)
        -- closureWithTuple pair =
        --     case pair of
        --         (a, b) -> \n -> a + b + n
        closureWithTupleDef : TypedDef
        closureWithTupleDef =
            { name = "closureWithTuple"
            , args = [ pVar "pair" ]
            , tipe =
                tLambda (tTuple (tType "Int" []) (tType "Int" []))
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "pair")
                    [ ( pTuple (pVar "a") (pVar "b")
                      , lambdaExpr [ pVar "n" ]
                            (binopsExpr
                                [ ( varExpr "a", "+" )
                                , ( varExpr "b", "+" )
                                ]
                                (varExpr "n")
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
                    (callExpr (varExpr "closureWithTuple")
                        [ tupleExpr (intExpr 1) (intExpr 2) ]
                    )
                    [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ closureWithTupleDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which the `::` branch of a case on a list returns a
lambda capturing the head, and gives it to `expectFn`.
-}
closureCapturingListHead : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingListHead expectFn _ =
    let
        -- closureFromList : List Int -> (Int -> Int)
        -- closureFromList xs =
        --     case xs of
        --         [] -> \x -> x
        --         h :: _ -> \x -> x * h
        -- (the tail is built as pVar "_", a variable named `_`)
        closureFromListDef : TypedDef
        closureFromListDef =
            { name = "closureFromList"
            , args = [ pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tType "Int" [] ])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList []
                      , lambdaExpr [ pVar "x" ] (varExpr "x")
                      )
                    , ( pCons (pVar "h") (pVar "_")
                      , lambdaExpr [ pVar "x" ]
                            (binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "h"))
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
                    (callExpr (varExpr "closureFromList")
                        [ listExpr [ intExpr 3, intExpr 4 ] ]
                    )
                    [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ closureFromListDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which lambdas in both branches of a case on a list
capture an `Int` argument, the one in the `::` branch also capturing the list
head, and gives it to `expectFn`. Both captures are `Int`s, from an argument
and from a pattern.
-}
closureCapturingMultipleTypes : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingMultipleTypes expectFn _ =
    let
        -- multiCapture : Int -> List Int -> (Int -> Int)
        -- multiCapture base xs =
        --     case xs of
        --         [] -> \x -> x + base
        --         h :: _ -> \x -> x + base + h
        -- (the tail is built as pVar "_", a variable named `_`)
        multiCaptureDef : TypedDef
        multiCaptureDef =
            { name = "multiCapture"
            , args = [ pVar "base", pVar "xs" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "List" [ tType "Int" [] ])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList []
                      , lambdaExpr [ pVar "x" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "base"))
                      )
                    , ( pCons (pVar "h") (pVar "_")
                      , lambdaExpr [ pVar "x" ]
                            (binopsExpr
                                [ ( varExpr "x", "+" )
                                , ( varExpr "base", "+" )
                                ]
                                (varExpr "h")
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
                    (callExpr (varExpr "multiCapture")
                        [ intExpr 10
                        , listExpr [ intExpr 5, intExpr 6 ]
                        ]
                    )
                    [ intExpr 100 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ multiCaptureDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- CLOSURE WITH RECURSION TESTS
-- ============================================================================


{-| Returns the cases combining closures with recursion, each checked with
`expectFn`.
-}
closureWithRecursionCases : (Src.Module -> Expectation) -> List TestCase
closureWithRecursionCases expectFn =
    [ { label = "Closure in recursive function", run = closureInRecursiveFunction expectFn }
    , { label = "Recursive closure", run = recursiveClosure expectFn }
    , { label = "Closure with tail recursion", run = closureWithTailRecursion expectFn }
    ]


{-| Builds a program in which a lambda capturing `n` is passed to a recursive,
not tail-recursive, `mapList`, and gives it to `expectFn`.
-}
closureInRecursiveFunction : (Src.Module -> Expectation) -> (() -> Expectation)
closureInRecursiveFunction expectFn _ =
    let
        -- mapList : (Int -> Int) -> List Int -> List Int
        -- mapList f xs =
        --     case xs of
        --         [] -> []
        --         h :: t -> f h :: mapList f t
        mapListDef : TypedDef
        mapListDef =
            { name = "mapList"
            , args = [ pVar "f", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tType "Int" []) (tType "Int" []))
                    (tLambda (tType "List" [ tType "Int" [] ])
                        (tType "List" [ tType "Int" [] ])
                    )
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "h") (pVar "t")
                      , binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "h" ], "::" ) ]
                            (callExpr (varExpr "mapList") [ varExpr "f", varExpr "t" ])
                      )
                    ]
            }

        -- addToAll : Int -> List Int -> List Int
        -- addToAll n xs = mapList (\x -> x + n) xs
        addToAllDef : TypedDef
        addToAllDef =
            { name = "addToAll"
            , args = [ pVar "n", pVar "xs" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "List" [ tType "Int" [] ])
                        (tType "List" [ tType "Int" [] ])
                    )
            , body =
                callExpr (varExpr "mapList")
                    [ lambdaExpr [ pVar "x" ]
                        (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))
                    , varExpr "xs"
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body =
                callExpr (varExpr "addToAll")
                    [ intExpr 10
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ mapListDef, addToAllDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which a recursive let-bound `go` refers only to its
own parameters and itself, and gives it to `expectFn`. Nothing from the
enclosing function is captured.
-}
recursiveClosure : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveClosure expectFn _ =
    let
        -- recursiveLet : Int -> Int
        -- recursiveLet n =
        --     let go acc m = if m <= 0 then acc else go (acc + m) (m - 1)
        --     in go 0 n
        recursiveLetDef : TypedDef
        recursiveLetDef =
            { name = "recursiveLet"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                letExpr
                    [ define "go"
                        [ pVar "acc", pVar "m" ]
                        (ifExpr
                            (binopsExpr [ ( varExpr "m", "<=" ) ] (intExpr 0))
                            (varExpr "acc")
                            (callExpr (varExpr "go")
                                [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "m")
                                , binopsExpr [ ( varExpr "m", "-" ) ] (intExpr 1)
                                ]
                            )
                        )
                    ]
                    (callExpr (varExpr "go") [ intExpr 0, varExpr "n" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "recursiveLet") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ recursiveLetDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds a program in which a tail-recursive let-bound `go` captures the
enclosing function's `factor`, and gives it to `expectFn`.
-}
closureWithTailRecursion : (Src.Module -> Expectation) -> (() -> Expectation)
closureWithTailRecursion expectFn _ =
    let
        -- tailRecWithClosure : Int -> Int -> Int
        -- tailRecWithClosure factor n =
        --     let go acc m = if m <= 0 then acc else go (acc + factor) (m - 1)
        --     in go 0 n
        tailRecWithClosureDef : TypedDef
        tailRecWithClosureDef =
            { name = "tailRecWithClosure"
            , args = [ pVar "factor", pVar "n" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                letExpr
                    [ define "go"
                        [ pVar "acc", pVar "m" ]
                        (ifExpr
                            (binopsExpr [ ( varExpr "m", "<=" ) ] (intExpr 0))
                            (varExpr "acc")
                            (callExpr (varExpr "go")
                                [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "factor")
                                , binopsExpr [ ( varExpr "m", "-" ) ] (intExpr 1)
                                ]
                            )
                        )
                    ]
                    (callExpr (varExpr "go") [ intExpr 0, varExpr "n" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "tailRecWithClosure") [ intExpr 10, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ tailRecWithClosureDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- HETEROGENEOUS CLOSURE ABI TESTS
-- ============================================================================


{-| Returns the cases in which one call site receives closures whose captures
differ in representation, each checked with `expectFn`.
-}
heteroClosureCases : (Src.Module -> Expectation) -> List TestCase
heteroClosureCases expectFn =
    [ { label = "Hetero closure: Int vs Float capture", run = heteroClosureIntFloat expectFn }
    , { label = "Hetero closure: boxed vs unboxed capture", run = heteroClosureBoxedUnboxed expectFn }
    ]


{-| Builds the program below and gives it to `expectFn`. The two branches of
the `if` partially apply different functions, one to an `Int` and one to a
`Float`, and the result is called at one call site. At closure boundaries the
MLIR back end gives an `Int` the type `i64` and a `Float` `f64`.

    addN : Int -> Int -> Int
    addN n x =
        n + x

    mulF : Float -> Int -> Int
    mulF f x =
        truncate (f * toFloat x)

    testValue : Int
    testValue =
        let
            f =
                if True then
                    addN 10

                else
                    mulF 2.5
        in
        f 3

-}
heteroClosureIntFloat : (Src.Module -> Expectation) -> (() -> Expectation)
heteroClosureIntFloat expectFn _ =
    let
        -- addN : Int -> Int -> Int
        -- addN n x = n + x
        addNDef : TypedDef
        addNDef =
            { name = "addN"
            , args = [ pVar "n", pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                binopsExpr [ ( varExpr "n", "+" ) ] (varExpr "x")
            }

        -- mulF : Float -> Int -> Int
        -- mulF f x = truncate (f * toFloat x)
        mulFDef : TypedDef
        mulFDef =
            { name = "mulF"
            , args = [ pVar "f", pVar "x" ]
            , tipe =
                tLambda (tType "Float" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Basics" "truncate")
                    [ binopsExpr
                        [ ( varExpr "f", "*" ) ]
                        (callExpr (qualVarExpr "Basics" "toFloat") [ varExpr "x" ])
                    ]
            }

        -- testValue =
        --     let f = if True then addN 10 else mulF 2.5
        --     in f 3
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "f"
                        []
                        (ifExpr (boolExpr True)
                            (callExpr (varExpr "addN") [ intExpr 10 ])
                            (callExpr (varExpr "mulF") [ floatExpr 2.5 ])
                        )
                    ]
                    (callExpr (varExpr "f") [ intExpr 3 ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ addNDef, mulFDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds the program below and gives it to `expectFn`. The two branches of
the `if` partially apply different functions, one to a value of the declared
type `Shape` and one to an `Int`, and the result is called at one call site.
At closure boundaries the MLIR back end gives a custom type the type
`!eco.value` and an `Int` `i64`.

    type Shape
        = Circle
        | Square

    shapeBonus : Shape -> Int -> Int
    shapeBonus shape x =
        case shape of
            Circle ->
                x + 10

            Square ->
                x + 20

    addN : Int -> Int -> Int
    addN n x =
        n + x

    testValue : Int
    testValue =
        let
            f =
                if True then
                    shapeBonus Circle

                else
                    addN 5
        in
        f 3

-}
heteroClosureBoxedUnboxed : (Src.Module -> Expectation) -> (() -> Expectation)
heteroClosureBoxedUnboxed expectFn _ =
    let
        shapeUnion : UnionDef
        shapeUnion =
            { name = "Shape"
            , args = []
            , ctors =
                [ { name = "Circle", args = [] }
                , { name = "Square", args = [] }
                ]
            }

        -- shapeBonus : Shape -> Int -> Int
        -- shapeBonus shape x = case shape of Circle -> x + 10; Square -> x + 20
        shapeBonusDef : TypedDef
        shapeBonusDef =
            { name = "shapeBonus"
            , args = [ pVar "shape", pVar "x" ]
            , tipe =
                tLambda (tType "Shape" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "shape")
                    [ ( pCtor "Circle" []
                      , binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 10)
                      )
                    , ( pCtor "Square" []
                      , binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 20)
                      )
                    ]
            }

        -- addN : Int -> Int -> Int
        -- addN n x = n + x
        addNDef : TypedDef
        addNDef =
            { name = "addN"
            , args = [ pVar "n", pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                binopsExpr [ ( varExpr "n", "+" ) ] (varExpr "x")
            }

        -- testValue =
        --     let f = if True then shapeBonus Circle else addN 5
        --     in f 3
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "f"
                        []
                        (ifExpr (boolExpr True)
                            (callExpr (varExpr "shapeBonus") [ ctorExpr "Circle" ])
                            (callExpr (varExpr "addN") [ intExpr 5 ])
                        )
                    ]
                    (callExpr (varExpr "f") [ intExpr 3 ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ shapeBonusDef, addNDef, testValueDef ]
                [ shapeUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- CLOSURE CAPTURE WITH DESTRUCTURING TESTS
-- ============================================================================
-- A captured variable here is used in the lambda body only as the scrutinee
-- of a case that binds its contents, so after monomorphization it is the
-- case's root and the root of a MonoDestruct path, never a MonoVarLocal.


{-| Returns the cases in which a captured variable is referenced only by
destructuring, each checked with `expectFn`.
-}
closureDestructCaptureCases : (Src.Module -> Expectation) -> List TestCase
closureDestructCaptureCases expectFn =
    [ { label = "Closure captures variable used only in single-ctor destruct"
      , run = closureCapturesDestructRoot expectFn
      }
    , { label = "Closure captures Maybe variable used only in case destruct"
      , run = closureCaptureMaybeCaseDestruct expectFn
      }
    ]


{-| Builds the program below and gives it to `expectFn`. Inside the lambda,
`w` is used only as the scrutinee of a case that unwraps it, so after
monomorphization it appears only as the root of the case and of the
`MonoDestruct` path binding `x`.

    type Wrapper a
        = Wrap a

    unwrapLater : Wrapper Int -> Int -> Int
    unwrapLater w =
        \dummy ->
            case w of
                Wrap x ->
                    x

    testValue : Int
    testValue =
        unwrapLater (Wrap 42) 0

-}
closureCapturesDestructRoot : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturesDestructRoot expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = [ "a" ]
            , ctors =
                [ { name = "Wrap", args = [ tVar "a" ] }
                ]
            }

        -- unwrapLater : Wrapper Int -> Int -> Int
        -- unwrapLater w = \dummy -> case w of Wrap x -> x
        unwrapLaterDef : TypedDef
        unwrapLaterDef =
            { name = "unwrapLater"
            , args = [ pVar "w" ]
            , tipe =
                tLambda (tType "Wrapper" [ tType "Int" [] ])
                    (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                lambdaExpr [ pVar "dummy" ]
                    (caseExpr (varExpr "w")
                        [ ( pCtor "Wrap" [ pVar "x" ]
                          , varExpr "x"
                          )
                        ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr
                    (callExpr (varExpr "unwrapLater")
                        [ callExpr (ctorExpr "Wrap") [ intExpr 42 ] ]
                    )
                    [ intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapLaterDef, testValueDef ]
                [ wrapperUnion ]
                []
    in
    expectFn modul


{-| Builds the program below and gives it to `expectFn`. Inside the lambda,
`m` is used only as the scrutinee of a case whose `Just` branch binds `s`, so
`m` appears as the root of the case and of the `MonoDestruct` path binding
`s`. The program declares its own `Maybe`.

    toLabel : Maybe String -> Int -> String
    toLabel m =
        \dummy ->
            case m of
                Just s ->
                    s

                Nothing ->
                    "none"

    testValue : String
    testValue =
        toLabel (Just "hello") 0

-}
closureCaptureMaybeCaseDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
closureCaptureMaybeCaseDestruct expectFn _ =
    let
        maybeUnion : UnionDef
        maybeUnion =
            { name = "Maybe"
            , args = [ "a" ]
            , ctors =
                [ { name = "Just", args = [ tVar "a" ] }
                , { name = "Nothing", args = [] }
                ]
            }

        -- toLabel : Maybe String -> Int -> String
        -- toLabel m = \dummy -> case m of Just s -> s; Nothing -> "none"
        toLabelDef : TypedDef
        toLabelDef =
            { name = "toLabel"
            , args = [ pVar "m" ]
            , tipe =
                tLambda (tType "Maybe" [ tType "String" [] ])
                    (tLambda (tType "Int" []) (tType "String" []))
            , body =
                lambdaExpr [ pVar "dummy" ]
                    (caseExpr (varExpr "m")
                        [ ( pCtor "Just" [ pVar "s" ]
                          , varExpr "s"
                          )
                        , ( pCtor "Nothing" []
                          , strExpr "none"
                          )
                        ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body =
                callExpr
                    (callExpr (varExpr "toLabel")
                        [ callExpr (ctorExpr "Just") [ strExpr "hello" ] ]
                    )
                    [ intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ toLabelDef, testValueDef ]
                [ maybeUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- CLOSURE CAPTURING CASE SCRUTINEE ROOT TESTS
-- ============================================================================
-- A captured variable here is used in the closure body only as the scrutinee
-- of a case. In the Int case the fallback branch is built with pVar "_", a
-- variable named `_` rather than a wildcard, so that case also binds it.


{-| Returns the cases in which a captured variable is referenced only as a case
scrutinee, each checked with `expectFn`.
-}
closureCaseScrutineeCases : (Src.Module -> Expectation) -> List TestCase
closureCaseScrutineeCases expectFn =
    [ { label = "Closure captures variable used only as case scrutinee (custom type)"
      , run = closureCapturesCaseScrutineeCustom expectFn
      }
    , { label = "Closure captures variable used only as case scrutinee (Int)"
      , run = closureCapturesCaseScrutineeInt expectFn
      }
    , { label = "Closure captures variable used only as case scrutinee (Bool)"
      , run = closureCapturesCaseScrutineeBool expectFn
      }
    , { label = "Nested closure captures case scrutinee from outer scope"
      , run = nestedClosureCapturesCaseScrutinee expectFn
      }
    ]


{-| Builds the program below and gives it to `expectFn`. The let-bound `pick`
refers to the enclosing `intensity`, a value of a declared enumeration, only as
the scrutinee of its case.

    type Intensity
        = Dull
        | Vivid

    pickByIntensity : Intensity -> Int -> Int -> Int
    pickByIntensity intensity dullVal vividVal =
        let
            pick a b =
                case intensity of
                    Dull ->
                        a

                    Vivid ->
                        b
        in
        pick dullVal vividVal

-}
closureCapturesCaseScrutineeCustom : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturesCaseScrutineeCustom expectFn _ =
    let
        intensityUnion : UnionDef
        intensityUnion =
            { name = "Intensity"
            , args = []
            , ctors =
                [ { name = "Dull", args = [] }
                , { name = "Vivid", args = [] }
                ]
            }

        -- pickByIntensity : Intensity -> Int -> Int -> Int
        -- pickByIntensity intensity dullVal vividVal =
        --     let pick a b = case intensity of Dull -> a; Vivid -> b
        --     in pick dullVal vividVal
        pickByIntensityDef : TypedDef
        pickByIntensityDef =
            { name = "pickByIntensity"
            , args = [ pVar "intensity", pVar "dullVal", pVar "vividVal" ]
            , tipe =
                tLambda (tType "Intensity" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                letExpr
                    [ define "pick"
                        [ pVar "a", pVar "b" ]
                        (caseExpr (varExpr "intensity")
                            [ ( pCtor "Dull" [], varExpr "a" )
                            , ( pCtor "Vivid" [], varExpr "b" )
                            ]
                        )
                    ]
                    (callExpr (varExpr "pick") [ varExpr "dullVal", varExpr "vividVal" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "pickByIntensity")
                    [ ctorExpr "Vivid", intExpr 1, intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ pickByIntensityDef, testValueDef ]
                [ intensityUnion ]
                []
    in
    expectFn modul


{-| Builds the program below and gives it to `expectFn`. The let-bound `pick`
refers to the enclosing `n`, an `Int`, only as the scrutinee of its case.

    chooseByN : Int -> Int -> Int -> Int
    chooseByN n a b =
        let
            pick x y =
                case n of
                    0 ->
                        x

                    _ ->
                        y
        in
        pick a b

The fallback is built with `pVar "_"`, a variable named `_` rather than a
wildcard, so it binds the value of `n`.

-}
closureCapturesCaseScrutineeInt : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturesCaseScrutineeInt expectFn _ =
    let
        -- chooseByN : Int -> Int -> Int -> Int
        -- chooseByN n a b =
        --     let pick x y = case n of 0 -> x; _ -> y
        --     in pick a b
        chooseByNDef : TypedDef
        chooseByNDef =
            { name = "chooseByN"
            , args = [ pVar "n", pVar "a", pVar "b" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                letExpr
                    [ define "pick"
                        [ pVar "x", pVar "y" ]
                        (caseExpr (varExpr "n")
                            [ ( pInt 0, varExpr "x" )
                            , ( pVar "_", varExpr "y" )
                            ]
                        )
                    ]
                    (callExpr (varExpr "pick") [ varExpr "a", varExpr "b" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "chooseByN")
                    [ intExpr 0, intExpr 10, intExpr 20 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ chooseByNDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds the program below and gives it to `expectFn`. The let-bound `pick`
refers to the enclosing `flag`, a `Bool`, only as the scrutinee of its case.

    pickByBool : Bool -> Int -> Int -> Int
    pickByBool flag a b =
        let
            pick x y =
                case flag of
                    True ->
                        x

                    False ->
                        y
        in
        pick a b

-}
closureCapturesCaseScrutineeBool : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturesCaseScrutineeBool expectFn _ =
    let
        -- pickByBool : Bool -> Int -> Int -> Int
        -- pickByBool flag a b =
        --     let pick x y = case flag of True -> x; False -> y
        --     in pick a b
        pickByBoolDef : TypedDef
        pickByBoolDef =
            { name = "pickByBool"
            , args = [ pVar "flag", pVar "a", pVar "b" ]
            , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                letExpr
                    [ define "pick"
                        [ pVar "x", pVar "y" ]
                        (caseExpr (varExpr "flag")
                            [ ( pCtor "True" [], varExpr "x" )
                            , ( pCtor "False" [], varExpr "y" )
                            ]
                        )
                    ]
                    (callExpr (varExpr "pick") [ varExpr "a", varExpr "b" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "pickByBool")
                    [ boolExpr True, intExpr 10, intExpr 20 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ pickByBoolDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Builds the program below and gives it to `expectFn`. `inner`, defined
inside the let-bound `outer`, refers to `nestedPick`'s argument `dir` only as
the scrutinee of its case, and `outer` does not refer to `dir` itself.

    type Dir
        = Left
        | Right

    nestedPick : Dir -> Int -> Int -> Int
    nestedPick dir a b =
        let
            outer x y =
                let
                    inner p q =
                        case dir of
                            Left ->
                                p

                            Right ->
                                q
                in
                inner x y
        in
        outer a b

-}
nestedClosureCapturesCaseScrutinee : (Src.Module -> Expectation) -> (() -> Expectation)
nestedClosureCapturesCaseScrutinee expectFn _ =
    let
        dirUnion : UnionDef
        dirUnion =
            { name = "Dir"
            , args = []
            , ctors =
                [ { name = "Left", args = [] }
                , { name = "Right", args = [] }
                ]
            }

        -- nestedPick : Dir -> Int -> Int -> Int
        -- nestedPick dir a b =
        --     let outer x y =
        --             let inner p q = case dir of Left -> p; Right -> q
        --             in inner x y
        --     in outer a b
        nestedPickDef : TypedDef
        nestedPickDef =
            { name = "nestedPick"
            , args = [ pVar "dir", pVar "a", pVar "b" ]
            , tipe =
                tLambda (tType "Dir" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                letExpr
                    [ define "outer"
                        [ pVar "x", pVar "y" ]
                        (letExpr
                            [ define "inner"
                                [ pVar "p", pVar "q" ]
                                (caseExpr (varExpr "dir")
                                    [ ( pCtor "Left" [], varExpr "p" )
                                    , ( pCtor "Right" [], varExpr "q" )
                                    ]
                                )
                            ]
                            (callExpr (varExpr "inner") [ varExpr "x", varExpr "y" ])
                        )
                    ]
                    (callExpr (varExpr "outer") [ varExpr "a", varExpr "b" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "nestedPick")
                    [ ctorExpr "Right", intExpr 10, intExpr 20 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ nestedPickDef, testValueDef ]
                [ dirUnion ]
                []
    in
    expectFn modul
