module SourceIR.CompositionOpCases exposing (expectSuite)

{-| Source programs that use function composition, `case` on a 3-tuple, `case`
on an `Order`, and a `case` whose branches are functions, so that a compiler
stage given them can be checked against these shapes.

The module asserts nothing itself. `expectSuite` takes an expectation function,
which decides what is done with a program and what counts as passing, and runs
it on every program here inside one elm-test test through
`Compiler.BulkCheck.bulkCheck`, so the first failing program is reported by its
label and the rest are not run.

Every program is a `Src.Module` built with `Compiler.AST.SourceBuilder`, and
each one's result is the top-level value `testValue`. Most are built with
`makeModule`: a module `Test` importing `Basics` and `List`, whose `testValue`
has no annotation and defines any helpers in a `let`. The two programs whose
`case` branches are functions instead declare `type Op = Add | Sub`, an
annotated `getOp : Op -> Int -> Int -> Int` and an annotated `testValue : Int`,
with the standard imports of `makeModuleWithTypedDefsUnionsAliases`. The
helpers `addOne` (`x + 1`) and `double` (`x * 2`) recur in the composition
programs.

The programs, in four groups:

  - Composition: `addOne >> double` bound to a name and applied to 9 (20);
    `addOne << double` bound to a name and applied to 5 (11); each of those two
    compositions applied directly, unnamed, to the same argument; and the chain
    `addOne >> double >> addOne` bound to a name and applied to 4 (11). The
    chain is built as one flat operator sequence, so its grouping is left to
    canonicalization.
  - `case` on a 3-tuple of `Int` literals: one matched by an all-literal
    pattern; `( 0, 1, 0 )` against an all-literal pattern, two patterns mixing
    literals and wildcards, and a final wildcard, where the first mixed pattern
    is the first that matches; and one whose single branch binds all three
    elements and sums them.
  - `case` on an `Order`: a let-bound function from `LT`, `EQ` and `GT` to
    strings, applied to `LT`; and a `case` on `Basics.compare 1 2` with the same
    three branches.
  - `case` returning functions: `getOp` answers each `Op` with a two-argument
    lambda, and `testValue` either applies `getOp Add` to 3 and 4 in a second
    call (7), or binds `getOp Add 5` in a `let` and applies it to 10 (15).

Among what is not tested: a `<<` chain of more than two functions, the `Sub`
branch of `getOp` being taken, a `case` on an `Order` with a wildcard branch,
and a 3-tuple whose elements are not all `Int`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pInt
        , pTuple3
        , pVar
        , qualVarExpr
        , strExpr
        , tLambda
        , tType
        , tuple3Expr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Composition operators and staged case " followed by
`condStr`, that passes when `expectFn` passes on every program in this module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Composition operators and staged case " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every labelled case in the module, in group order, each checking its
program with `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    compositionOpCases expectFn
        ++ tripleCaseCases expectFn
        ++ orderCaseCases expectFn
        ++ caseReturningFunctionCases expectFn



-- ============================================================================
-- FUNCTION COMPOSITION OPERATORS >> and <<
-- ============================================================================


{-| Returns the five composition cases, each checking its program with
`expectFn`.
-}
compositionOpCases : (Src.Module -> Expectation) -> List TestCase
compositionOpCases expectFn =
    [ { label = "ComposeR (>>) two functions", run = composeRightTwoFunctions expectFn }
    , { label = "ComposeL (<<) two functions", run = composeLeftTwoFunctions expectFn }
    , { label = "ComposeR applied to value", run = composeRightApplied expectFn }
    , { label = "ComposeL applied to value", run = composeLeftApplied expectFn }
    , { label = "ComposeR chain of three functions", run = composeRightChain expectFn }
    ]


{-| Gives `expectFn` a program that binds `addOneThenDouble = addOne >> double`
in a `let` and applies it to 9, so `testValue` is `(9 + 1) * 2`, which is 20.
-}
composeRightTwoFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeRightTwoFunctions expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        composed =
            define "addOneThenDouble" [] (binopsExpr [ ( varExpr "addOne", ">>" ) ] (varExpr "double"))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double, composed ]
                    (callExpr (varExpr "addOneThenDouble") [ intExpr 9 ])
                )
    in
    expectFn modul


{-| Gives `expectFn` a program that binds `doubleThenAddOne = addOne << double`
in a `let` and applies it to 5. `<<` applies its right operand first, so
`testValue` is `(5 * 2) + 1`, which is 11.
-}
composeLeftTwoFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeLeftTwoFunctions expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        composed =
            define "doubleThenAddOne" [] (binopsExpr [ ( varExpr "addOne", "<<" ) ] (varExpr "double"))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double, composed ]
                    (callExpr (varExpr "doubleThenAddOne") [ intExpr 5 ])
                )
    in
    expectFn modul


{-| Gives `expectFn` a program whose `testValue` applies `addOne >> double`
directly to 9, with no name bound to the composition, giving 20.
-}
composeRightApplied : (Src.Module -> Expectation) -> (() -> Expectation)
composeRightApplied expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double ]
                    (callExpr (binopsExpr [ ( varExpr "addOne", ">>" ) ] (varExpr "double")) [ intExpr 9 ])
                )
    in
    expectFn modul


{-| Gives `expectFn` a program whose `testValue` applies `addOne << double`
directly to 5, with no name bound to the composition, giving 11.
-}
composeLeftApplied : (Src.Module -> Expectation) -> (() -> Expectation)
composeLeftApplied expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double ]
                    (callExpr (binopsExpr [ ( varExpr "addOne", "<<" ) ] (varExpr "double")) [ intExpr 5 ])
                )
    in
    expectFn modul


{-| Gives `expectFn` a program that binds `chain = addOne >> double >> addOne`
in a `let` and applies it to 4, so `testValue` is `((4 + 1) * 2) + 1`, or 11.

The two operators are built as one flat sequence, leaving their grouping to
canonicalization; either grouping gives the same function.

-}
composeRightChain : (Src.Module -> Expectation) -> (() -> Expectation)
composeRightChain expectFn _ =
    let
        addOne =
            define "addOne" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))

        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        composed =
            define "chain"
                []
                (binopsExpr [ ( varExpr "addOne", ">>" ), ( varExpr "double", ">>" ) ] (varExpr "addOne"))

        modul =
            makeModule "testValue"
                (letExpr [ addOne, double, composed ]
                    (callExpr (varExpr "chain") [ intExpr 4 ])
                )
    in
    expectFn modul



-- ============================================================================
-- CASE ON TRIPLE (3-TUPLE)
-- ============================================================================


{-| Returns the three cases that match on a 3-tuple, each checking its program
with `expectFn`.
-}
tripleCaseCases : (Src.Module -> Expectation) -> List TestCase
tripleCaseCases expectFn =
    [ { label = "Case on triple with all-zero literal pattern", run = caseTripleAllZero expectFn }
    , { label = "Case on triple with mixed wildcard patterns", run = caseTripleMixedWildcards expectFn }
    , { label = "Case on triple with variable extraction", run = caseTripleVarExtraction expectFn }
    ]


{-| Gives `expectFn` a program whose `testValue` is a `case` on `( 0, 0, 0 )`
with the branches `( 0, 0, 0 )` and `_`, so the literal pattern matches and the
result is `"all zero"`.
-}
caseTripleAllZero : (Src.Module -> Expectation) -> (() -> Expectation)
caseTripleAllZero expectFn _ =
    let
        subject =
            tuple3Expr (intExpr 0) (intExpr 0) (intExpr 0)

        modul =
            makeModule "testValue"
                (caseExpr subject
                    [ ( pTuple3 (pInt 0) (pInt 0) (pInt 0), strExpr "all zero" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul


{-| Gives `expectFn` a program whose `testValue` is a `case` on `( 0, 1, 0 )`
with the branches `( 0, 0, 0 )`, `( 0, _, _ )`, `( _, _, 0 )` and `_`.

The subject matches both middle patterns; the first of them wins, so the result
is `"x zero"`.

-}
caseTripleMixedWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
caseTripleMixedWildcards expectFn _ =
    let
        subject =
            tuple3Expr (intExpr 0) (intExpr 1) (intExpr 0)

        modul =
            makeModule "testValue"
                (caseExpr subject
                    [ ( pTuple3 (pInt 0) (pInt 0) (pInt 0), strExpr "all zero" )
                    , ( pTuple3 (pInt 0) pAnything pAnything, strExpr "x zero" )
                    , ( pTuple3 pAnything pAnything (pInt 0), strExpr "z zero" )
                    , ( pAnything, strExpr "none zero" )
                    ]
                )
    in
    expectFn modul


{-| Gives `expectFn` a program whose `testValue` is a `case` on `( 1, 2, 3 )`
with the single branch `( a, b, c ) -> a + b + c`, giving 6.
-}
caseTripleVarExtraction : (Src.Module -> Expectation) -> (() -> Expectation)
caseTripleVarExtraction expectFn _ =
    let
        subject =
            tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)

        modul =
            makeModule "testValue"
                (caseExpr subject
                    [ ( pTuple3 (pVar "a") (pVar "b") (pVar "c")
                      , binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
                      )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- CASE ON ORDER TYPE (LT, EQ, GT)
-- ============================================================================


{-| Returns the two cases that match on an `Order`, each checking its program
with `expectFn`.
-}
orderCaseCases : (Src.Module -> Expectation) -> List TestCase
orderCaseCases expectFn =
    [ { label = "Case on Order with LT/EQ/GT patterns", run = caseOrderPatterns expectFn }
    , { label = "Case on compare result", run = caseCompareResult expectFn }
    ]


{-| Gives `expectFn` a program that defines, in a `let`, an unannotated
`orderToStr` mapping `LT`, `EQ` and `GT` to `"less"`, `"equal"` and `"greater"`,
and applies it to `LT`, giving `"less"`.
-}
caseOrderPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseOrderPatterns expectFn _ =
    let
        orderToStr =
            define "orderToStr"
                [ pVar "ord" ]
                (caseExpr (varExpr "ord")
                    [ ( pCtor "LT" [], strExpr "less" )
                    , ( pCtor "EQ" [], strExpr "equal" )
                    , ( pCtor "GT" [], strExpr "greater" )
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ orderToStr ]
                    (callExpr (varExpr "orderToStr") [ ctorExpr "LT" ])
                )
    in
    expectFn modul


{-| Gives `expectFn` a program whose `testValue` is a `case` on
`Basics.compare 1 2`, written qualified, with branches for `LT`, `EQ` and `GT`,
so the subject is a call rather than a variable and the result is `"less"`.
-}
caseCompareResult : (Src.Module -> Expectation) -> (() -> Expectation)
caseCompareResult expectFn _ =
    let
        compareCall =
            callExpr (qualVarExpr "Basics" "compare") [ intExpr 1, intExpr 2 ]

        modul =
            makeModule "testValue"
                (caseExpr compareCall
                    [ ( pCtor "LT" [], strExpr "less" )
                    , ( pCtor "EQ" [], strExpr "equal" )
                    , ( pCtor "GT" [], strExpr "greater" )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- CASE RETURNING FUNCTIONS
-- ============================================================================


{-| Returns the two cases whose `case` branches are functions, each checking its
program with `expectFn`.
-}
caseReturningFunctionCases : (Src.Module -> Expectation) -> List TestCase
caseReturningFunctionCases expectFn =
    [ { label = "Case returns lambda, then apply", run = caseReturnsLambdaThenApply expectFn }
    , { label = "Case returns lambda, partial application", run = caseReturnsLambdaPartialApp expectFn }
    ]


{-| Gives `expectFn` a module `Test` declaring `type Op = Add | Sub` and
`getOp : Op -> Int -> Int -> Int`, which takes one argument and answers `Add`
with `\a b -> a + b` and `Sub` with `\a b -> a - b`.

`testValue : Int` calls `getOp Add` and then applies the result to 3 and 4 in a
second call, giving 7.

-}
caseReturnsLambdaThenApply : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsLambdaThenApply expectFn _ =
    let
        opUnion : UnionDef
        opUnion =
            { name = "Op"
            , args = []
            , ctors =
                [ { name = "Add", args = [] }
                , { name = "Sub", args = [] }
                ]
            }

        intType =
            tType "Int" []

        getOpDef : TypedDef
        getOpDef =
            { name = "getOp"
            , args = [ pVar "op" ]
            , tipe = tLambda (tType "Op" []) (tLambda intType (tLambda intType intType))
            , body =
                caseExpr (varExpr "op")
                    [ ( pCtor "Add" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pCtor "Sub" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body =
                callExpr
                    (callExpr (varExpr "getOp") [ ctorExpr "Add" ])
                    [ intExpr 3, intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getOpDef, testValueDef ] [ opUnion ] []
    in
    expectFn modul


{-| Gives `expectFn` the same module `Test`, `Op` and `getOp` as
`caseReturnsLambdaThenApply`, with a different `testValue : Int`.

Here `testValue` binds `addFive = getOp Add 5` in a `let`, one call supplying
the `Op` and the first of the lambda's two arguments, and applies `addFive` to
10, giving 15.

-}
caseReturnsLambdaPartialApp : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturnsLambdaPartialApp expectFn _ =
    let
        opUnion : UnionDef
        opUnion =
            { name = "Op"
            , args = []
            , ctors =
                [ { name = "Add", args = [] }
                , { name = "Sub", args = [] }
                ]
            }

        intType =
            tType "Int" []

        getOpDef : TypedDef
        getOpDef =
            { name = "getOp"
            , args = [ pVar "op" ]
            , tipe = tLambda (tType "Op" []) (tLambda intType (tLambda intType intType))
            , body =
                caseExpr (varExpr "op")
                    [ ( pCtor "Add" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pCtor "Sub" []
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body =
                letExpr
                    [ define "addFive" [] (callExpr (varExpr "getOp") [ ctorExpr "Add", intExpr 5 ]) ]
                    (callExpr (varExpr "addFive") [ intExpr 10 ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getOpDef, testValueDef ] [ opUnion ] []
    in
    expectFn modul
