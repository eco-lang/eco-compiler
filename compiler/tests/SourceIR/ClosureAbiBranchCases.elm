module SourceIR.ClosureAbiBranchCases exposing (expectSuite)

{-| Source programs that make function values and call them, for whatever
pipeline stage a caller wants to run them through.

A function value here is a lambda, a lambda that captures variables from where
it was made, or the result of calling a function whose definition takes fewer
parameters than its type has arrows and returns a lambda for the rest. In every
case but `lambdaCapturingDifferent`, different function values of one type meet
at one place: the parameter of a higher-order function passed different lambdas
at different calls, the result of an `if` whose branches are different lambdas,
or the payload of a constructor. A compiler that gives function values a calling
convention has to make every value that reaches one place callable the same way
there, and those cases give a stage that gets this wrong something to fail on.
In `lambdaCapturingDifferent` the values do not meet: one lambda makes two
closures capturing different values, and each is called under its own name.

This module builds the programs and asserts nothing about them. `expectSuite`
hands each built `Src.Module`, in turn, to the caller's expectation function,
which decides the stage and the property checked. Each program is a module
named `Test` with type-annotated top-level definitions, one of which is
`testValue`, an `Int`.

The cases, put in one test that `Compiler.BulkCheck.bulkCheck` runs in order,
stopping at the first failure:

  - `applyDifferentLambdas`: `apply f x = f x`, called with an adding lambda and
    with a multiplying lambda.
  - `caseReturningLambdas`: `picker`, typed `Bool -> Int -> Int` but taking one
    parameter, returns one of two lambdas from an `if`. Its label says "Case",
    but the program uses `if`.
  - `higherOrderMultiSite`: `applyTwice f x = f (f x)`, called with two
    different lambdas.
  - `lambdaCapturingDifferent`: `makeAdder n` returns a lambda capturing `n`,
    and two adders made from it with different `n` are each called.
  - `ifReturningClosures`: `choose`, typed with four parameters but taking
    three, returns from an `if` one of two lambdas capturing different
    parameters, and the result is applied at once to a fourth argument.
  - `customTypeWithFnField`: a type `Op` whose one constructor holds an
    `Int -> Int`, unwrapped by a `case` in `runOp` and called; `runOp` is given
    two `Op`s holding different lambdas.

Among what is not tested: lambdas of more than one parameter passed as values,
and function values stored in records, tuples or lists.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Closure ABI branch " followed by `condStr`, that
passes when `expectFn` passes for every program in this module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Closure ABI branch " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of this module, labelled, each handing its program to
`expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Apply different lambdas", run = applyDifferentLambdas expectFn }
    , { label = "Case returning lambdas", run = caseReturningLambdas expectFn }
    , { label = "Higher-order called at multiple sites", run = higherOrderMultiSite expectFn }
    , { label = "Lambda capturing different vars", run = lambdaCapturingDifferent expectFn }
    , { label = "If returning closures", run = ifReturningClosures expectFn }
    , { label = "Custom type with function field", run = customTypeWithFnField expectFn }
    ]


{-| Returns the deferred check of a case, which hands `expectFn` a program in
which `apply f x = f x` is called with `\n -> n + 1` and with `\n -> n * 2`.
-}
applyDifferentLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
applyDifferentLambdas expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "apply"
                  , args = [ pVar "f", pVar "x" ]
                  , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tLambda (tType "Int" []) (tType "Int" []))
                  , body = callExpr (varExpr "f") [ varExpr "x" ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "a" [] (callExpr (varExpr "apply") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)), intExpr 5 ])
                            , define "b" [] (callExpr (varExpr "apply") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "*" ) ] (intExpr 2)), intExpr 5 ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
    in
    expectFn modul


{-| Returns the deferred check of a case, which hands `expectFn` a program in
which `picker b`, typed `Bool -> Int -> Int`, returns `\x -> x + 10` or
`\x -> x * 10` from an `if`, and `testValue` binds `picker True` and applies it
to 3.
-}
caseReturningLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturningLambdas expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "picker"
                  , args = [ pVar "b" ]
                  , tipe = tLambda (tType "Bool" []) (tLambda (tType "Int" []) (tType "Int" []))
                  , body =
                        ifExpr (varExpr "b")
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 10)))
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 10)))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "f" [] (callExpr (varExpr "picker") [ ctorExpr "True" ]) ]
                            (callExpr (varExpr "f") [ intExpr 3 ])
                  }
                ]
    in
    expectFn modul


{-| Returns the deferred check of a case, which hands `expectFn` a program in
which `applyTwice f x = f (f x)` is called with `\n -> n + 1` and with
`\n -> n * 3`.
-}
higherOrderMultiSite : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderMultiSite expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "applyTwice"
                  , args = [ pVar "f", pVar "x" ]
                  , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tLambda (tType "Int" []) (tType "Int" []))
                  , body = callExpr (varExpr "f") [ callExpr (varExpr "f") [ varExpr "x" ] ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "a" [] (callExpr (varExpr "applyTwice") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)), intExpr 0 ])
                            , define "b" [] (callExpr (varExpr "applyTwice") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "*" ) ] (intExpr 3)), intExpr 1 ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
    in
    expectFn modul


{-| Returns the deferred check of a case, which hands `expectFn` a program in
which `makeAdder n` returns `\x -> x + n`, and `testValue` makes `makeAdder 1`
and `makeAdder 10` and calls each with 5.
-}
lambdaCapturingDifferent : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaCapturingDifferent expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "makeAdder"
                  , args = [ pVar "n" ]
                  , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
                  , body = lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "add1" [] (callExpr (varExpr "makeAdder") [ intExpr 1 ])
                            , define "add10" [] (callExpr (varExpr "makeAdder") [ intExpr 10 ])
                            , define "a" [] (callExpr (varExpr "add1") [ intExpr 5 ])
                            , define "b" [] (callExpr (varExpr "add10") [ intExpr 5 ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
    in
    expectFn modul


{-| Returns the deferred check of a case, which hands `expectFn` a program in
which `choose flag a b`, typed `Bool -> Int -> Int -> Int -> Int`, returns
`\x -> x + a` or `\x -> x + b` from an `if`, and `testValue` is
`(choose True 100 200) 5`.
-}
ifReturningClosures : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningClosures expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "choose"
                  , args = [ pVar "flag", pVar "a", pVar "b" ]
                  , tipe = tLambda (tType "Bool" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))))
                  , body =
                        ifExpr (varExpr "flag")
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "a")))
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "b")))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        callExpr (callExpr (varExpr "choose") [ ctorExpr "True", intExpr 100, intExpr 200 ]) [ intExpr 5 ]
                  }
                ]
    in
    expectFn modul


{-| Returns the deferred check of a case, which hands `expectFn` a program
declaring `type Op = Op (Int -> Int)`, in which `runOp` takes the function out
of an `Op` with a `case` and applies it to 10, and is called with an `Op` of
`\x -> x + 1` and one of `\x -> x * 2`.
-}
customTypeWithFnField : (Src.Module -> Expectation) -> (() -> Expectation)
customTypeWithFnField expectFn _ =
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "runOp"
                  , args = [ pVar "op" ]
                  , tipe = tLambda (tType "Op" []) (tType "Int" [])
                  , body =
                        caseExpr (varExpr "op")
                            [ ( pCtor "Op" [ pVar "f" ], callExpr (varExpr "f") [ intExpr 10 ] ) ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "a" [] (callExpr (varExpr "runOp") [ callExpr (ctorExpr "Op") [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)) ] ])
                            , define "b" [] (callExpr (varExpr "runOp") [ callExpr (ctorExpr "Op") [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2)) ] ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
                [ { name = "Op", args = [], ctors = [ { name = "Op", args = [ tLambda (tType "Int" []) (tType "Int" []) ] } ] } ]
                []
    in
    expectFn modul
