module SourceIR.MultiDefCases exposing (expectSuite)

{-| Checks a pipeline stage on modules with several top-level definitions,
where something meant to be numbered once per module could wrongly start again
with each definition.

The expression and pattern ids the canonicalizer assigns are the case in point:
one counter runs through all of a module's top-level values, as
`Compiler.Canonicalize.Ids` describes, so two definitions of the same shape must
still get different ids. Many definitions here have the same or a similar
shape, and several reuse the same argument names. The module asserts nothing
itself: what is checked is decided by the expectation function passed to
`expectSuite`, which is given each case's module in turn until one fails.

Each case module is built with `makeModuleWithDefs`, is named `Test`, has no
annotations, and ends with a definition `testValue` from which every other
definition is reachable. The numbers are integer literals.

The cases:

  - Two definitions with identical bodies, `a` and `b`, both `1 + 2`.
  - Three values `a`, `b` and `c`, bound to `1`, `2` and `3`.
  - Two one-argument functions, `f x = x + 1` and `g y = y * 2`.
  - A value and functions of one, two and three arguments.
  - `f x = g x` with `g` defined after it. This is labelled as functions that
    call each other, but `g` does not call `f`.
  - Definitions whose bodies are each a `let`, a `case` on an integer, an
    `if`, a lambda, a record, or a single operator application, one kind per
    case.
  - Fifteen definitions, `def1` to `def15`, with varied bodies.
  - Two definitions whose bodies are a `let` nested inside a `let`.
  - Functions taking a tuple, list or record pattern as their argument, one
    kind per case. The list patterns `[ a ]` and `[ x, y ]` are refutable,
    which Elm source rejects as an incomplete match, and the calls in
    `testValue` match them.
  - Eight definitions of different kinds of body in one module.

Among what is not tested: annotated definitions, custom types, aliases and
ports; mutual recursion; a `let` with more than one definition; and a call
that does not match a refutable argument pattern.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, boolExpr, callExpr, caseExpr, define, ifExpr, intExpr, lambdaExpr, letExpr, listExpr, makeModuleWithDefs, pAnything, pInt, pList, pRecord, pTuple, pVar, recordExpr, strExpr, tuple3Expr, tupleExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Multiple top-level definitions " followed by
`condStr`, that applies `expectFn` to each case's module in order through
`bulkCheck`, stopping at the first failing case and reporting only that one.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Multiple top-level definitions " ++ condStr) (\() -> bulkCheck (testCases expectFn))


{-| Returns every case, the basic ones then the complex ones, each applying
`expectFn` to its module.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    basicMultiDefCases expectFn
        ++ complexMultiDefCases expectFn


{-| Returns the twelve basic cases, from two identical definitions up to a
module of fifteen definitions.
-}
basicMultiDefCases : (Src.Module -> Expectation) -> List TestCase
basicMultiDefCases expectFn =
    [ { label = "Two identical structure definitions", run = twoIdenticalStructureDefinitions expectFn }
    , { label = "Three simple value definitions", run = threeSimpleValueDefinitions expectFn }
    , { label = "Multiple function definitions with same arity", run = multipleFunctionsSameArity expectFn }
    , { label = "Multiple function definitions with different arities", run = multipleFunctionsDifferentArities expectFn }
    , { label = "Functions that call each other", run = functionsCallEachOther expectFn }
    , { label = "Multiple definitions with let expressions", run = multipleDefsWithLet expectFn }
    , { label = "Multiple definitions with case expressions", run = multipleDefsWithCase expectFn }
    , { label = "Multiple definitions with if expressions", run = multipleDefsWithIf expectFn }
    , { label = "Multiple definitions with lambdas", run = multipleDefsWithLambdas expectFn }
    , { label = "Multiple definitions with records", run = multipleDefsWithRecords expectFn }
    , { label = "Multiple definitions with binary operators", run = multipleDefsWithBinops expectFn }
    , { label = "Large module with many definitions", run = largeModuleManyDefs expectFn }
    ]


{-| Returns the five cases with nested `let`s, tuple, list and record argument
patterns, and a mix of kinds of body.
-}
complexMultiDefCases : (Src.Module -> Expectation) -> List TestCase
complexMultiDefCases expectFn =
    [ { label = "Definitions with nested lets", run = nestedLetsMultipleDefs expectFn }
    , { label = "Definitions with tuple patterns", run = tuplePatternMultipleDefs expectFn }
    , { label = "Definitions with list patterns", run = listPatternMultipleDefs expectFn }
    , { label = "Definitions with record patterns", run = recordPatternMultipleDefs expectFn }
    , { label = "Mixed expressions and patterns across definitions", run = mixedExpressionsAndPatterns expectFn }
    ]


{-| Applies `expectFn` to a module defining `a = 1 + 2`, `b = 1 + 2` and
`testValue = ( a, b )`. The two bodies are identical, so numbering that
restarted with each definition would give them the same ids.
-}
twoIdenticalStructureDefinitions : (Src.Module -> Expectation) -> (() -> Expectation)
twoIdenticalStructureDefinitions expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                , ( "b", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                , ( "testValue", [], tupleExpr (varExpr "a") (varExpr "b") )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `a = 1`, `b = 2`, `c = 3` and
`testValue = ( a, b, c )`.
-}
threeSimpleValueDefinitions : (Src.Module -> Expectation) -> (() -> Expectation)
threeSimpleValueDefinitions expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a", [], intExpr 1 )
                , ( "b", [], intExpr 2 )
                , ( "c", [], intExpr 3 )
                , ( "testValue", [], tuple3Expr (varExpr "a") (varExpr "b") (varExpr "c") )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `f x = x + 1`, `g y = y * 2` and
`testValue = ( f 1, g 2 )`.
-}
multipleFunctionsSameArity : (Src.Module -> Expectation) -> (() -> Expectation)
multipleFunctionsSameArity expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f", [ pVar "x" ], binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) )
                , ( "g", [ pVar "y" ], binopsExpr [ ( varExpr "y", "*" ) ] (intExpr 2) )
                , ( "testValue", [], tupleExpr (callExpr (varExpr "f") [ intExpr 1 ]) (callExpr (varExpr "g") [ intExpr 2 ]) )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `a = 42`, `f x = x`,
`g x y = x + y`, `h x y z = x + y + z` and
`testValue = ( ( a, f 1 ), ( g 1 2, h 1 2 3 ) )`.
-}
multipleFunctionsDifferentArities : (Src.Module -> Expectation) -> (() -> Expectation)
multipleFunctionsDifferentArities expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a", [], intExpr 42 )
                , ( "f", [ pVar "x" ], varExpr "x" )
                , ( "g", [ pVar "x", pVar "y" ], binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y") )
                , ( "h"
                  , [ pVar "x", pVar "y", pVar "z" ]
                  , binopsExpr [ ( varExpr "x", "+" ), ( varExpr "y", "+" ) ] (varExpr "z")
                  )
                , ( "testValue"
                  , []
                  , tupleExpr
                        (tupleExpr (varExpr "a") (callExpr (varExpr "f") [ intExpr 1 ]))
                        (tupleExpr (callExpr (varExpr "g") [ intExpr 1, intExpr 2 ]) (callExpr (varExpr "h") [ intExpr 1, intExpr 2, intExpr 3 ]))
                  )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `f x = g x`, `g y = y + 1` and
`testValue = f 1`. `f` refers to `g`, which is defined after it; `g` does not
call `f`, so `testValue` reaches `g` only through `f`.
-}
functionsCallEachOther : (Src.Module -> Expectation) -> (() -> Expectation)
functionsCallEachOther expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f", [ pVar "x" ], callExpr (varExpr "g") [ varExpr "x" ] )
                , ( "g", [ pVar "y" ], binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 1) )
                , ( "testValue", [], callExpr (varExpr "f") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `a = let x = 1 in x`,
`b = let y = 2 in y` and `testValue = ( a, b )`.
-}
multipleDefsWithLet : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithLet expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a", [], letExpr [ define "x" [] (intExpr 1) ] (varExpr "x") )
                , ( "b", [], letExpr [ define "y" [] (intExpr 2) ] (varExpr "y") )
                , ( "testValue", [], tupleExpr (varExpr "a") (varExpr "b") )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `f x`, a `case` on `x` giving `1`
for `0` and `2` otherwise, `g y`, the same with `3` and `4`, and
`testValue = ( f 1, g 2 )`.
-}
multipleDefsWithCase : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithCase expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f"
                  , [ pVar "x" ]
                  , caseExpr (varExpr "x")
                        [ ( pInt 0, intExpr 1 )
                        , ( pAnything, intExpr 2 )
                        ]
                  )
                , ( "g"
                  , [ pVar "y" ]
                  , caseExpr (varExpr "y")
                        [ ( pInt 0, intExpr 3 )
                        , ( pAnything, intExpr 4 )
                        ]
                  )
                , ( "testValue", [], tupleExpr (callExpr (varExpr "f") [ intExpr 1 ]) (callExpr (varExpr "g") [ intExpr 2 ]) )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `a`, `b` and `c` as
`if True then 1 else 2`, `if True then 3 else 4` and `if True then 5 else 6`,
and `testValue = ( a, b, c )`.
-}
multipleDefsWithIf : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithIf expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a", [], ifExpr (boolExpr True) (intExpr 1) (intExpr 2) )
                , ( "b", [], ifExpr (boolExpr True) (intExpr 3) (intExpr 4) )
                , ( "c", [], ifExpr (boolExpr True) (intExpr 5) (intExpr 6) )
                , ( "testValue", [], tuple3Expr (varExpr "a") (varExpr "b") (varExpr "c") )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `f = \x -> x`, `g = \y -> y + 1`
and `h = \a b -> a + b`, none taking arguments of its own, and
`testValue = ( f 1, g 2, h 3 4 )`.
-}
multipleDefsWithLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithLambdas expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f", [], lambdaExpr [ pVar "x" ] (varExpr "x") )
                , ( "g", [], lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 1)) )
                , ( "h", [], lambdaExpr [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")) )
                , ( "testValue", [], tuple3Expr (callExpr (varExpr "f") [ intExpr 1 ]) (callExpr (varExpr "g") [ intExpr 2 ]) (callExpr (varExpr "h") [ intExpr 3, intExpr 4 ]) )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `a = { x = 1 }`,
`b = { y = 2, z = 3 }`, `c = { p = 4, q = 5, r = 6 }` and
`testValue = ( a, b, c )`.
-}
multipleDefsWithRecords : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithRecords expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a", [], recordExpr [ ( "x", intExpr 1 ) ] )
                , ( "b", [], recordExpr [ ( "y", intExpr 2 ), ( "z", intExpr 3 ) ] )
                , ( "c", [], recordExpr [ ( "p", intExpr 4 ), ( "q", intExpr 5 ), ( "r", intExpr 6 ) ] )
                , ( "testValue", [], tuple3Expr (varExpr "a") (varExpr "b") (varExpr "c") )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `a = 1 + 2`, `b = 3 * 4`,
`c = 5 - 6`, `d = 7 / 8` and `testValue = ( ( a, b ), ( c, d ) )`.
-}
multipleDefsWithBinops : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithBinops expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                , ( "b", [], binopsExpr [ ( intExpr 3, "*" ) ] (intExpr 4) )
                , ( "c", [], binopsExpr [ ( intExpr 5, "-" ) ] (intExpr 6) )
                , ( "d", [], binopsExpr [ ( intExpr 7, "/" ) ] (intExpr 8) )
                , ( "testValue", [], tupleExpr (tupleExpr (varExpr "a") (varExpr "b")) (tupleExpr (varExpr "c") (varExpr "d")) )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module of fifteen definitions, `def1` to `def15`,
whose bodies are integer and string literals, operator applications, a
variable, a `let`, an `if`, a record, a tuple, a list and a lambda, and two of
which are functions of one argument and one a function of two. `testValue`
uses all fifteen in nested tuples, calling each function.
-}
largeModuleManyDefs : (Src.Module -> Expectation) -> (() -> Expectation)
largeModuleManyDefs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "def1", [], intExpr 1 )
                , ( "def2", [], intExpr 2 )
                , ( "def3", [], intExpr 3 )
                , ( "def4", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                , ( "def5", [], binopsExpr [ ( intExpr 3, "*" ) ] (intExpr 4) )
                , ( "def6", [ pVar "x" ], varExpr "x" )
                , ( "def7", [ pVar "x" ], binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) )
                , ( "def8", [], letExpr [ define "a" [] (intExpr 1) ] (varExpr "a") )
                , ( "def9", [], ifExpr (boolExpr True) (intExpr 1) (intExpr 2) )
                , ( "def10", [], recordExpr [ ( "x", intExpr 1 ) ] )
                , ( "def11", [], tupleExpr (intExpr 1) (intExpr 2) )
                , ( "def12", [], listExpr [ intExpr 1, intExpr 2, intExpr 3 ] )
                , ( "def13", [], lambdaExpr [ pVar "n" ] (varExpr "n") )
                , ( "def14", [ pVar "a", pVar "b" ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                , ( "def15", [], strExpr "hello" )
                , ( "testValue"
                  , []
                  , tupleExpr
                        (tupleExpr
                            (tuple3Expr (varExpr "def1") (varExpr "def2") (varExpr "def3"))
                            (tuple3Expr (varExpr "def4") (varExpr "def5") (callExpr (varExpr "def6") [ intExpr 1 ]))
                        )
                        (tupleExpr
                            (tuple3Expr (callExpr (varExpr "def7") [ intExpr 1 ]) (varExpr "def8") (varExpr "def9"))
                            (tuple3Expr
                                (tuple3Expr (varExpr "def10") (varExpr "def11") (varExpr "def12"))
                                (tuple3Expr (callExpr (varExpr "def13") [ intExpr 1 ]) (callExpr (varExpr "def14") [ intExpr 1, intExpr 2 ]) (varExpr "def15"))
                                (intExpr 0)
                            )
                        )
                  )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining
`a = let x = (let y = 1 in y) in x`, `b` the same with `p`, `q` and `2`, and
`testValue = ( a, b )`.
-}
nestedLetsMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLetsMultipleDefs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "a"
                  , []
                  , letExpr [ define "x" [] (letExpr [ define "y" [] (intExpr 1) ] (varExpr "y")) ]
                        (varExpr "x")
                  )
                , ( "b"
                  , []
                  , letExpr [ define "p" [] (letExpr [ define "q" [] (intExpr 2) ] (varExpr "q")) ]
                        (varExpr "p")
                  )
                , ( "testValue", [], tupleExpr (varExpr "a") (varExpr "b") )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `f ( a, b ) = a + b`,
`g ( x, y ) = x * y` and `testValue = ( f ( 1, 2 ), g ( 3, 4 ) )`.
-}
tuplePatternMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
tuplePatternMultipleDefs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f", [ pTuple (pVar "a") (pVar "b") ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                , ( "g", [ pTuple (pVar "x") (pVar "y") ], binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "y") )
                , ( "testValue"
                  , []
                  , tupleExpr
                        (callExpr (varExpr "f") [ tupleExpr (intExpr 1) (intExpr 2) ])
                        (callExpr (varExpr "g") [ tupleExpr (intExpr 3) (intExpr 4) ])
                  )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `f [ a ] = a`,
`g [ x, y ] = x + y` and `testValue = ( f [ 1 ], g [ 2, 3 ] )`. Both argument
patterns are refutable, which Elm source rejects as an incomplete match; the
calls in `testValue` match them.
-}
listPatternMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
listPatternMultipleDefs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f", [ pList [ pVar "a" ] ], varExpr "a" )
                , ( "g", [ pList [ pVar "x", pVar "y" ] ], binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y") )
                , ( "testValue"
                  , []
                  , tupleExpr
                        (callExpr (varExpr "f") [ listExpr [ intExpr 1 ] ])
                        (callExpr (varExpr "g") [ listExpr [ intExpr 2, intExpr 3 ] ])
                  )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module defining `f { x } = x`,
`g { a, b } = a + b` and `testValue = ( f { x = 1 }, g { a = 2, b = 3 } )`.
-}
recordPatternMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternMultipleDefs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f", [ pRecord [ "x" ] ], varExpr "x" )
                , ( "g", [ pRecord [ "a", "b" ] ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                , ( "testValue"
                  , []
                  , tupleExpr
                        (callExpr (varExpr "f") [ recordExpr [ ( "x", intExpr 1 ) ] ])
                        (callExpr (varExpr "g") [ recordExpr [ ( "a", intExpr 2 ), ( "b", intExpr 3 ) ] ])
                  )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module of eight definitions with different kinds
of body: a literal `value`; `func x = x + 1`; `withLet`; `withCase n`, a `case`
on an integer; `withIf b`; `withLambda`, a two-argument lambda; `withRecord`;
and `withTuple`, which takes a tuple pattern. `testValue` uses all eight, and
the names `x`, `a` and `b` are each bound in more than one definition.
-}
mixedExpressionsAndPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
mixedExpressionsAndPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "value", [], intExpr 42 )
                , ( "func", [ pVar "x" ], binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) )
                , ( "withLet"
                  , []
                  , letExpr [ define "a" [] (intExpr 1) ] (varExpr "a")
                  )
                , ( "withCase"
                  , [ pVar "n" ]
                  , caseExpr (varExpr "n")
                        [ ( pInt 0, intExpr 0 )
                        , ( pAnything, intExpr 1 )
                        ]
                  )
                , ( "withIf"
                  , [ pVar "b" ]
                  , ifExpr (varExpr "b") (intExpr 1) (intExpr 2)
                  )
                , ( "withLambda"
                  , []
                  , lambdaExpr [ pVar "x", pVar "y" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
                  )
                , ( "withRecord"
                  , []
                  , recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]
                  )
                , ( "withTuple"
                  , [ pTuple (pVar "a") (pVar "b") ]
                  , tupleExpr (varExpr "a") (varExpr "b")
                  )
                , ( "testValue"
                  , []
                  , tupleExpr
                        (tupleExpr
                            (tupleExpr (varExpr "value") (callExpr (varExpr "func") [ intExpr 1 ]))
                            (tupleExpr (varExpr "withLet") (callExpr (varExpr "withCase") [ intExpr 0 ]))
                        )
                        (tupleExpr
                            (tupleExpr (callExpr (varExpr "withIf") [ boolExpr True ]) (callExpr (varExpr "withLambda") [ intExpr 1, intExpr 2 ]))
                            (tupleExpr (varExpr "withRecord") (callExpr (varExpr "withTuple") [ tupleExpr (intExpr 1) (intExpr 2) ]))
                        )
                  )
                ]
    in
    expectFn modul
