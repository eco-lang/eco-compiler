module SourceIR.KernelPapAbiCases exposing (expectSuite)

{-| Supplies programs that use `==` and `++` in a few settings, for the stage
tests that run the standard source programs (`SourceIR.Suite.StandardTestSuites`):
`==` on two types in one module, `==` beside a `case` with a string-literal
branch, `==` inside a lambda passed to `List.map`, and `++` on lists.

In a module's MLIR, every call to a kernel function's symbol has to use the
argument and result types of that symbol's one declaration. A program that
reaches the same operator at two types is where those types could come out
differently, and only `equalityOnMultipleTypes` does that.

Despite the module's name and the test's name, no case partially applies a
function in the source program.

The module asserts nothing itself. `expectSuite` is given an expectation
function, and the stage and the property checked are whatever that function
checks. Every case runs inside one test through `Compiler.BulkCheck`, so a
failure reports only the first failing case.

Every program is built with `makeModule`: a module `Test` whose one value,
`testValue`, is the expression described below, importing `Basics` and `List`.
The cases are:

  - `equalityOnIntWithStringCase`: a `case` with a string-literal branch
    beside an `==` on two integer literals, both results returned.
  - `equalityOnMultipleTypes`: `==` on integer literals and on strings, both
    results returned.
  - `equalityLambdaPassedToMap`: `==` inside a lambda passed to `List.map`.
  - `appendOnLists`: `++` on two lists.

Among what is not tested: `/=` and the comparison operators, `++` on strings,
and an operator used as a function value, such as `(==)`, or partially
applied.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pAnything
        , pStr
        , pVar
        , qualVarExpr
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named `Kernel PAP ABI consistency` followed by `condStr`,
that passes when `expectFn` passes for every program in this module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel PAP ABI consistency " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the labelled cases, each applying `expectFn` to one program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Equality on Int with string case", run = equalityOnIntWithStringCase expectFn }
    , { label = "Equality on multiple types", run = equalityOnMultipleTypes expectFn }
    , { label = "Equality lambda passed to map", run = equalityLambdaPassedToMap expectFn }
    , { label = "Append on lists", run = appendOnLists expectFn }
    ]


{-| Applies `expectFn` to a program whose `let` defines `classify`, a `case` on
its `String` argument with a branch for the literal `"foo"` and a wildcard
branch, and `result = 1 == 2`, and whose body is the pair
`( classify "foo", result )`.
-}
equalityOnIntWithStringCase : (Src.Module -> Expectation) -> (() -> Expectation)
equalityOnIntWithStringCase expectFn _ =
    let
        classifyBody =
            caseExpr (varExpr "s")
                [ ( pStr "foo", strExpr "matched" )
                , ( pAnything, strExpr "other" )
                ]

        modul =
            makeModule "testValue"
                (letExpr
                    [ define "classify" [ pVar "s" ] classifyBody
                    , define "result"
                        []
                        (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 2))
                    ]
                    (tupleExpr (callExpr (varExpr "classify") [ strExpr "foo" ]) (varExpr "result"))
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `let` binds `intEq = 1 == 2` and
`strEq = "a" == "b"`, and whose body is the pair `( intEq, strEq )`.
-}
equalityOnMultipleTypes : (Src.Module -> Expectation) -> (() -> Expectation)
equalityOnMultipleTypes expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "intEq" [] (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 2))
                    , define "strEq" [] (binopsExpr [ ( strExpr "a", "==" ) ] (strExpr "b"))
                    ]
                    (tupleExpr (varExpr "intEq") (varExpr "strEq"))
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `List.map (\x -> x == 5) [ 1, 5, 3 ]`.
-}
equalityLambdaPassedToMap : (Src.Module -> Expectation) -> (() -> Expectation)
equalityLambdaPassedToMap expectFn _ =
    let
        eqLambda =
            lambdaExpr [ pVar "x" ]
                (binopsExpr [ ( varExpr "x", "==" ) ] (intExpr 5))

        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ eqLambda
                    , listExpr [ intExpr 1, intExpr 5, intExpr 3 ]
                    ]
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program `[ 1 ] ++ [ 2, 3 ]`.
-}
appendOnLists : (Src.Module -> Expectation) -> (() -> Expectation)
appendOnLists expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( listExpr [ intExpr 1 ], "++" ) ]
                    (listExpr [ intExpr 2, intExpr 3 ])
                )
    in
    expectFn modul
