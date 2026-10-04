module SourceIR.MaybeResultCases exposing (expectSuite)

{-| Supplies a few small programs for a compiler stage check to run on:
functions over `Maybe` written in the program itself, `Basics.min` and
`Basics.max` at four types, `isNaN` and `isInfinite` applied to float divisions
by zero, integer division by zero, and a self-recursive `let` function that
uses a parameter of the function around it. A stage that mishandles one of
these, in a way the check detects, fails the one test, and the failure names the
label of the first case the check rejects.

The module asserts nothing about the programs itself. `expectSuite` takes the
check to apply, as every case module in `SourceIR.Suite.StandardTestSuites`
does, and runs all the cases as one test through `Compiler.BulkCheck`, which
stops at the first case that fails. No program is ever evaluated, so the value
a program would compute is not checked here.

The programs are built with `Compiler.AST.SourceBuilder` and every one defines
`testValue`. They come in two shapes. A case built with
`makeModuleWithTypedDefsUnionsAliases` is a module named `TestMod` whose
top-level values all carry annotations, and it imports `Maybe` among the
standard set, which is where `Just` and `Nothing` come from. A case built with
`makeModule` is a module named `Test` holding only an unannotated `testValue`,
and it imports only `Basics` and `List`. In those unannotated programs an
integer literal stays of type `number`, since nothing fixes it to `Int`.

The one test, named `Maybe/MinMax/FloatSpecial` followed by `condStr`, passes
when the check accepts each of these programs:

  - Six `TestMod` programs, two for each of `myMap`, `myWithDefault` and
    `myAndThen`. Both define that `Int`-annotated function by a `case` on
    `Just` and `Nothing`; one applies it to a `Just` and the other to
    `Nothing`.
  - One `TestMod` program that defines `polyWithDefault : a -> Maybe a -> a`
    the same way and uses it at `Int`.
  - Eight `Test` programs, each calling `Basics.min` or `Basics.max` on two
    integer literals, two float literals, two strings or two characters.
  - Four `Test` programs calling `Basics.isNaN` or `Basics.isInfinite`, on
    `0 / 0` and `1 / 0` built from float literals and on the literal `3.14`.
  - Two `Test` programs dividing with `//` by the literal `0`: `10 // 0` and
    `(0 - 5) // 0`.
  - One `TestMod` program whose `processItems` defines, in a `let`, an
    unannotated `takeMore` that calls itself and compares against
    `processItems`'s parameter `threshold`.

Among what is not tested: any `Result` value, despite the module's name; the
`Maybe.map`, `Maybe.withDefault` and `Maybe.andThen` of the `Maybe` module,
since every program here defines its own; `min` and `max` on tuples or lists;
`modBy` or `remainderBy` by zero; and `NaN` or an infinity written as a literal.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , caseExpr
        , chrExpr
        , ctorExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pCtor
        , pList
        , pVar
        , qualVarExpr
        , strExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `Maybe/MinMax/FloatSpecial` followed by `condStr`,
that applies `expectFn` to the programs in this module in order and fails at the
first one it rejects, naming that program's label; the programs after it are not
checked.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Maybe/MinMax/FloatSpecial " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each checked with `expectFn`, in the
order the groups below are listed.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    maybeCases expectFn
        ++ minMaxCases expectFn
        ++ floatSpecialCases expectFn
        ++ intDivZeroCases expectFn
        ++ letRecCaptureCases expectFn



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


{-| The type `Int`, as written in an annotation.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| Builds the type `Maybe a`, as written in an annotation.
-}
tMaybe : Src.Type -> Src.Type
tMaybe a =
    tType "Maybe" [ a ]



-- ============================================================================
-- MAYBE FUNCTIONS DEFINED IN THE PROGRAM
-- ============================================================================


{-| Returns the seven cases whose programs define their own function over
`Maybe` by a `case` on `Just` and `Nothing`, each checked with `expectFn`.
-}
maybeCases : (Src.Module -> Expectation) -> List TestCase
maybeCases expectFn =
    [ { label = "Maybe map on Just (local)", run = maybeMapJust expectFn }
    , { label = "Maybe map on Nothing (local)", run = maybeMapNothing expectFn }
    , { label = "Maybe withDefault on Just (local)", run = maybeWithDefaultJust expectFn }
    , { label = "Maybe withDefault on Nothing (local)", run = maybeWithDefaultNothing expectFn }
    , { label = "Maybe andThen on Just (local)", run = maybeAndThenJust expectFn }
    , { label = "Maybe andThen on Nothing (local)", run = maybeAndThenNothing expectFn }
    , { label = "Polymorphic pipe with Maybe.withDefault", run = polyPipeMaybeWithDefault expectFn }
    ]


{-| Checks with `expectFn` a program that defines
`myMap : (Int -> Int) -> Maybe Int -> Maybe Int` by a `case` on `Just` and
`Nothing`, and whose `testValue` is `myMap` applied to a lambda doubling its
argument and to `Just 42`.
-}
maybeMapJust : (Src.Module -> Expectation) -> (() -> Expectation)
maybeMapJust expectFn _ =
    let
        myMapDef : TypedDef
        myMapDef =
            { name = "myMap"
            , args = [ pVar "f", pVar "mx" ]
            , tipe = tLambda (tLambda tInt tInt) (tLambda (tMaybe tInt) (tMaybe tInt))
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ]
                      , callExpr (ctorExpr "Just") [ callExpr (varExpr "f") [ varExpr "x" ] ]
                      )
                    , ( pCtor "Nothing" [], ctorExpr "Nothing" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body =
                callExpr (varExpr "myMap")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                    , callExpr (ctorExpr "Just") [ intExpr 42 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "TestMod"
            [ myMapDef, testValueDef ]
            []
            []
        )


{-| Checks with `expectFn` the program of `maybeMapJust` with `Nothing` in place
of `Just 42`.
-}
maybeMapNothing : (Src.Module -> Expectation) -> (() -> Expectation)
maybeMapNothing expectFn _ =
    let
        myMapDef : TypedDef
        myMapDef =
            { name = "myMap"
            , args = [ pVar "f", pVar "mx" ]
            , tipe = tLambda (tLambda tInt tInt) (tLambda (tMaybe tInt) (tMaybe tInt))
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ]
                      , callExpr (ctorExpr "Just") [ callExpr (varExpr "f") [ varExpr "x" ] ]
                      )
                    , ( pCtor "Nothing" [], ctorExpr "Nothing" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body =
                callExpr (varExpr "myMap")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                    , ctorExpr "Nothing"
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "TestMod"
            [ myMapDef, testValueDef ]
            []
            []
        )


{-| Checks with `expectFn` a program that defines
`myWithDefault : Int -> Maybe Int -> Int` by a `case` on `Just` and `Nothing`,
and whose `testValue` is `myWithDefault 0 (Just 42)`.
-}
maybeWithDefaultJust : (Src.Module -> Expectation) -> (() -> Expectation)
maybeWithDefaultJust expectFn _ =
    let
        withDefaultDef : TypedDef
        withDefaultDef =
            { name = "myWithDefault"
            , args = [ pVar "d", pVar "mx" ]
            , tipe = tLambda tInt (tLambda (tMaybe tInt) tInt)
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], varExpr "d" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "myWithDefault")
                    [ intExpr 0
                    , callExpr (ctorExpr "Just") [ intExpr 42 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "TestMod"
            [ withDefaultDef, testValueDef ]
            []
            []
        )


{-| Checks with `expectFn` the program of `maybeWithDefaultJust` with `Nothing`
in place of `Just 42`.
-}
maybeWithDefaultNothing : (Src.Module -> Expectation) -> (() -> Expectation)
maybeWithDefaultNothing expectFn _ =
    let
        withDefaultDef : TypedDef
        withDefaultDef =
            { name = "myWithDefault"
            , args = [ pVar "d", pVar "mx" ]
            , tipe = tLambda tInt (tLambda (tMaybe tInt) tInt)
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], varExpr "d" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "myWithDefault")
                    [ intExpr 0
                    , ctorExpr "Nothing"
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "TestMod"
            [ withDefaultDef, testValueDef ]
            []
            []
        )


{-| Checks with `expectFn` a program that defines
`myAndThen : (Int -> Maybe Int) -> Maybe Int -> Maybe Int` by a `case` on
`Just` and `Nothing`, and whose `testValue` is `myAndThen` applied to a lambda
that returns `Just` of a positive argument and `Nothing` otherwise, and to
`Just 42`.
-}
maybeAndThenJust : (Src.Module -> Expectation) -> (() -> Expectation)
maybeAndThenJust expectFn _ =
    let
        andThenDef : TypedDef
        andThenDef =
            { name = "myAndThen"
            , args = [ pVar "f", pVar "mx" ]
            , tipe = tLambda (tLambda tInt (tMaybe tInt)) (tLambda (tMaybe tInt) (tMaybe tInt))
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ], callExpr (varExpr "f") [ varExpr "x" ] )
                    , ( pCtor "Nothing" [], ctorExpr "Nothing" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body =
                callExpr (varExpr "myAndThen")
                    [ lambdaExpr [ pVar "x" ]
                        (ifExpr
                            (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 0))
                            (callExpr (ctorExpr "Just") [ varExpr "x" ])
                            (ctorExpr "Nothing")
                        )
                    , callExpr (ctorExpr "Just") [ intExpr 42 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "TestMod"
            [ andThenDef, testValueDef ]
            []
            []
        )


{-| Checks with `expectFn` a program that defines `myAndThen` as
`maybeAndThenJust` does, and whose `testValue` is `myAndThen` applied to a
lambda returning `Just` of twice its argument and to `Nothing`.
-}
maybeAndThenNothing : (Src.Module -> Expectation) -> (() -> Expectation)
maybeAndThenNothing expectFn _ =
    let
        andThenDef : TypedDef
        andThenDef =
            { name = "myAndThen"
            , args = [ pVar "f", pVar "mx" ]
            , tipe = tLambda (tLambda tInt (tMaybe tInt)) (tLambda (tMaybe tInt) (tMaybe tInt))
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ], callExpr (varExpr "f") [ varExpr "x" ] )
                    , ( pCtor "Nothing" [], ctorExpr "Nothing" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body =
                callExpr (varExpr "myAndThen")
                    [ lambdaExpr [ pVar "x" ]
                        (callExpr (ctorExpr "Just") [ binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2) ])
                    , ctorExpr "Nothing"
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "TestMod"
            [ andThenDef, testValueDef ]
            []
            []
        )


{-| Checks with `expectFn` a program that defines the polymorphic
`polyWithDefault : a -> Maybe a -> a` by a `case` on `Just` and `Nothing`, and
whose `Int`-annotated `testValue` is `polyWithDefault 0 (Just 99)`.

The case's label speaks of a pipe and `Maybe.withDefault`, but the program has
neither: it uses its own function and applies it directly.

-}
polyPipeMaybeWithDefault : (Src.Module -> Expectation) -> (() -> Expectation)
polyPipeMaybeWithDefault expectFn _ =
    let
        polyWithDefaultDef : TypedDef
        polyWithDefaultDef =
            { name = "polyWithDefault"
            , args = [ pVar "fallback", pVar "mx" ]
            , tipe = tLambda (tVar "a") (tLambda (tType "Maybe" [ tVar "a" ]) (tVar "a"))
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], varExpr "fallback" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "polyWithDefault")
                    [ intExpr 0
                    , callExpr (ctorExpr "Just") [ intExpr 99 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "TestMod"
            [ polyWithDefaultDef, testValueDef ]
            []
            []
        )



-- ============================================================================
-- COMPARABLE MIN/MAX
-- ============================================================================


{-| Returns the eight cases calling `Basics.min` or `Basics.max` on two
literals of one type, each checked with `expectFn`.
-}
minMaxCases : (Src.Module -> Expectation) -> List TestCase
minMaxCases expectFn =
    [ { label = "min on Int", run = minOnInt expectFn }
    , { label = "max on Int", run = maxOnInt expectFn }
    , { label = "min on Float", run = minOnFloat expectFn }
    , { label = "max on Float", run = maxOnFloat expectFn }
    , { label = "min on String", run = minOnString expectFn }
    , { label = "max on String", run = maxOnString expectFn }
    , { label = "min on Char", run = minOnChar expectFn }
    , { label = "max on Char", run = maxOnChar expectFn }
    ]


{-| Checks with `expectFn` a program whose `testValue` is `Basics.min 3 7`, on
integer literals.
-}
minOnInt : (Src.Module -> Expectation) -> (() -> Expectation)
minOnInt expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ intExpr 3, intExpr 7 ])
        )


{-| Checks with `expectFn` a program whose `testValue` is `Basics.max 3 7`, on
integer literals.
-}
maxOnInt : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnInt expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ intExpr 3, intExpr 7 ])
        )


{-| Checks with `expectFn` a program whose `testValue` is `Basics.min 1.5 2.5`.
-}
minOnFloat : (Src.Module -> Expectation) -> (() -> Expectation)
minOnFloat expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ floatExpr 1.5, floatExpr 2.5 ])
        )


{-| Checks with `expectFn` a program whose `testValue` is `Basics.max 1.5 2.5`.
-}
maxOnFloat : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnFloat expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ floatExpr 1.5, floatExpr 2.5 ])
        )


{-| Checks with `expectFn` a program whose `testValue` is
`Basics.min "apple" "zebra"`.
-}
minOnString : (Src.Module -> Expectation) -> (() -> Expectation)
minOnString expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ strExpr "apple", strExpr "zebra" ])
        )


{-| Checks with `expectFn` a program whose `testValue` is
`Basics.max "apple" "zebra"`.
-}
maxOnString : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnString expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ strExpr "apple", strExpr "zebra" ])
        )


{-| Checks with `expectFn` a program whose `testValue` is `Basics.min 'a' 'z'`.
-}
minOnChar : (Src.Module -> Expectation) -> (() -> Expectation)
minOnChar expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ chrExpr "a", chrExpr "z" ])
        )


{-| Checks with `expectFn` a program whose `testValue` is `Basics.max 'a' 'z'`.
-}
maxOnChar : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnChar expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ chrExpr "a", chrExpr "z" ])
        )



-- ============================================================================
-- FLOAT SPECIAL VALUES
-- ============================================================================


{-| Returns the four cases calling `Basics.isNaN` or `Basics.isInfinite`, each
checked with `expectFn`.
-}
floatSpecialCases : (Src.Module -> Expectation) -> List TestCase
floatSpecialCases expectFn =
    [ { label = "isNaN on 0/0", run = isNanDivZero expectFn }
    , { label = "isNaN on normal float", run = isNanNormal expectFn }
    , { label = "isInfinite on 1/0", run = isInfiniteDivZero expectFn }
    , { label = "isInfinite on normal float", run = isInfiniteNormal expectFn }
    ]


{-| Checks with `expectFn` a program whose `testValue` is `Basics.isNaN`
applied to `0 / 0`, both operands float literals.
-}
isNanDivZero : (Src.Module -> Expectation) -> (() -> Expectation)
isNanDivZero expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isNaN")
                [ binopsExpr [ ( floatExpr 0.0, "/" ) ] (floatExpr 0.0) ]
            )
        )


{-| Checks with `expectFn` a program whose `testValue` is `Basics.isNaN 3.14`.
-}
isNanNormal : (Src.Module -> Expectation) -> (() -> Expectation)
isNanNormal expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isNaN") [ floatExpr 3.14 ])
        )


{-| Checks with `expectFn` a program whose `testValue` is `Basics.isInfinite`
applied to the float literal `1` divided with `/` by the float literal `0`.
-}
isInfiniteDivZero : (Src.Module -> Expectation) -> (() -> Expectation)
isInfiniteDivZero expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isInfinite")
                [ binopsExpr [ ( floatExpr 1.0, "/" ) ] (floatExpr 0.0) ]
            )
        )


{-| Checks with `expectFn` a program whose `testValue` is
`Basics.isInfinite 3.14`.
-}
isInfiniteNormal : (Src.Module -> Expectation) -> (() -> Expectation)
isInfiniteNormal expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isInfinite") [ floatExpr 3.14 ])
        )



-- ============================================================================
-- INTEGER DIVISION BY ZERO
-- ============================================================================


{-| Returns the two cases dividing with `//` by zero, each checked with
`expectFn`.

Their labels say the result is 0, but no program is evaluated, so no result
is checked.

-}
intDivZeroCases : (Src.Module -> Expectation) -> List TestCase
intDivZeroCases expectFn =
    [ { label = "10 // 0 returns 0", run = intDivByZero expectFn }
    , { label = "-5 // 0 returns 0", run = intDivByZeroNeg expectFn }
    ]


{-| Checks with `expectFn` a program whose `testValue` is `10 // 0`, on integer
literals.
-}
intDivByZero : (Src.Module -> Expectation) -> (() -> Expectation)
intDivByZero expectFn _ =
    expectFn
        (makeModule "testValue"
            (binopsExpr [ ( intExpr 10, "//" ) ] (intExpr 0))
        )


{-| Checks with `expectFn` a program whose `testValue` is `(0 - 5) // 0`, on
integer literals. The dividend is a subtraction, not a negative literal or a
negation.
-}
intDivByZeroNeg : (Src.Module -> Expectation) -> (() -> Expectation)
intDivByZeroNeg expectFn _ =
    expectFn
        (makeModule "testValue"
            (binopsExpr
                [ ( binopsExpr [ ( intExpr 0, "-" ) ] (intExpr 5), "//" ) ]
                (intExpr 0)
            )
        )



-- ============================================================================
-- LET-REC CLOSURE CAPTURING OUTER SCOPE
-- ============================================================================


{-| Returns the one case whose program has a self-recursive `let` function that
uses a variable of the function around it, checked with `expectFn`.
-}
letRecCaptureCases : (Src.Module -> Expectation) -> List TestCase
letRecCaptureCases expectFn =
    [ { label = "Let-rec closure capturing outer scope", run = letRecCaptureOuterScope expectFn }
    ]


{-| Checks with `expectFn` a program that defines
`processItems : Int -> List Int -> List Int`, and whose `testValue` is
`processItems 3 [ 1, 5, 2, 7, 4 ]`.

On a non-empty list, `processItems` keeps the head and, in a `let`, defines
`takeMore` without an annotation. `takeMore` takes elements from the front of
a list while each is greater than `threshold`, a parameter of `processItems`,
and calls itself on the rest.

-}
letRecCaptureOuterScope : (Src.Module -> Expectation) -> (() -> Expectation)
letRecCaptureOuterScope expectFn _ =
    let
        takeMoreDef =
            define "takeMore"
                [ pVar "xs" ]
                (caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "y") (pVar "ys")
                      , ifExpr
                            (binopsExpr [ ( varExpr "y", ">" ) ] (varExpr "threshold"))
                            (binopsExpr
                                [ ( varExpr "y", "::" ) ]
                                (callExpr (varExpr "takeMore") [ varExpr "ys" ])
                            )
                            (listExpr [])
                      )
                    ]
                )

        processItemsDef : TypedDef
        processItemsDef =
            { name = "processItems"
            , args = [ pVar "threshold", pVar "items" ]
            , tipe =
                tLambda tInt
                    (tLambda (tType "List" [ tInt ])
                        (tType "List" [ tInt ])
                    )
            , body =
                caseExpr (varExpr "items")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "x") (pVar "rest")
                      , letExpr [ takeMoreDef ]
                            (binopsExpr
                                [ ( varExpr "x", "::" ) ]
                                (callExpr (varExpr "takeMore") [ varExpr "rest" ])
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tInt ]
            , body =
                callExpr (varExpr "processItems")
                    [ intExpr 3
                    , listExpr [ intExpr 1, intExpr 5, intExpr 2, intExpr 7, intExpr 4 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ processItemsDef, testValueDef ]
                []
                []
    in
    expectFn modul
