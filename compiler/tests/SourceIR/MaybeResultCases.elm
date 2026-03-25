module SourceIR.MaybeResultCases exposing (expectSuite)

{-| Test cases covering gaps from e2e-to-elmtest.md:

  - Gap 1 (partial): Maybe.andThen, Maybe.map, Maybe.withDefault patterns
  - Gap 9: Polymorphic pipe with Maybe.withDefault
  - Gap 17: Comparable min/max on String/Char
  - Gap 28: Float special values (isNaN, isInfinite edge cases)
  - Gap 29: Integer division by zero
  - Gap 19: Let-rec closure capturing outer scope

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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Maybe/MinMax/FloatSpecial " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    maybeCases expectFn
        ++ minMaxCases expectFn
        ++ floatSpecialCases expectFn
        ++ intDivZeroCases expectFn
        ++ letRecCaptureCases expectFn



-- ============================================================================
-- TYPE/MODULE HELPERS
-- ============================================================================


tInt : Src.Type
tInt =
    tType "Int" []


tMaybe : Src.Type -> Src.Type
tMaybe a =
    tType "Maybe" [ a ]



-- ============================================================================
-- MAYBE PATTERN MATCHING (Gap 1 / Gap 42)
-- ============================================================================


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


{-| Local implementation of map: case mx of Just x -> Just (f x); Nothing -> Nothing
Applied to Just 42.
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


{-| myMap (\\x -> x \* 2) Nothing -> Nothing
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


{-| let withDefault d mx = case mx of Just x -> x; Nothing -> d
in withDefault 0 (Just 42) -> 42
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


{-| myWithDefault 0 Nothing -> 0
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


{-| let andThen f mx = case mx of Just x -> f x; Nothing -> Nothing
in andThen (\\x -> if x > 0 then Just x else Nothing) (Just 42)
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


{-| myAndThen (\\x -> Just (x \* 2)) Nothing -> Nothing
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


{-| polyWithDefault : a -> Maybe a -> a
polyWithDefault fallback mx = Maybe.withDefault fallback mx
Desugared pipe, instantiated at Int. Tests pipe intermediate type monomorphization.
-}
polyPipeMaybeWithDefault : (Src.Module -> Expectation) -> (() -> Expectation)
polyPipeMaybeWithDefault expectFn _ =
    let
        -- Local polyWithDefault that reimplements withDefault as case:
        -- polyWithDefault fallback mx = case mx of Just x -> x; Nothing -> fallback
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
-- COMPARABLE MIN/MAX (Gap 17)
-- ============================================================================


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


{-| min 3 7 -> 3
-}
minOnInt : (Src.Module -> Expectation) -> (() -> Expectation)
minOnInt expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ intExpr 3, intExpr 7 ])
        )


{-| max 3 7 -> 7
-}
maxOnInt : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnInt expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ intExpr 3, intExpr 7 ])
        )


{-| min 1.5 2.5 -> 1.5
-}
minOnFloat : (Src.Module -> Expectation) -> (() -> Expectation)
minOnFloat expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ floatExpr 1.5, floatExpr 2.5 ])
        )


{-| max 1.5 2.5 -> 2.5
-}
maxOnFloat : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnFloat expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ floatExpr 1.5, floatExpr 2.5 ])
        )


{-| min "apple" "zebra" -> "apple"
-}
minOnString : (Src.Module -> Expectation) -> (() -> Expectation)
minOnString expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ strExpr "apple", strExpr "zebra" ])
        )


{-| max "apple" "zebra" -> "zebra"
-}
maxOnString : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnString expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ strExpr "apple", strExpr "zebra" ])
        )


{-| min 'a' 'z' -> 'a'
-}
minOnChar : (Src.Module -> Expectation) -> (() -> Expectation)
minOnChar expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "min") [ chrExpr "a", chrExpr "z" ])
        )


{-| max 'a' 'z' -> 'z'
-}
maxOnChar : (Src.Module -> Expectation) -> (() -> Expectation)
maxOnChar expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "max") [ chrExpr "a", chrExpr "z" ])
        )



-- ============================================================================
-- FLOAT SPECIAL VALUES (Gap 28)
-- ============================================================================


floatSpecialCases : (Src.Module -> Expectation) -> List TestCase
floatSpecialCases expectFn =
    [ { label = "isNaN on 0/0", run = isNanDivZero expectFn }
    , { label = "isNaN on normal float", run = isNanNormal expectFn }
    , { label = "isInfinite on 1/0", run = isInfiniteDivZero expectFn }
    , { label = "isInfinite on normal float", run = isInfiniteNormal expectFn }
    ]


{-| isNaN (0.0 / 0.0) -> True
-}
isNanDivZero : (Src.Module -> Expectation) -> (() -> Expectation)
isNanDivZero expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isNaN")
                [ binopsExpr [ ( floatExpr 0.0, "/" ) ] (floatExpr 0.0) ]
            )
        )


{-| isNaN 3.14 -> False
-}
isNanNormal : (Src.Module -> Expectation) -> (() -> Expectation)
isNanNormal expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isNaN") [ floatExpr 3.14 ])
        )


{-| isInfinite (1.0 / 0.0) -> True
-}
isInfiniteDivZero : (Src.Module -> Expectation) -> (() -> Expectation)
isInfiniteDivZero expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isInfinite")
                [ binopsExpr [ ( floatExpr 1.0, "/" ) ] (floatExpr 0.0) ]
            )
        )


{-| isInfinite 3.14 -> False
-}
isInfiniteNormal : (Src.Module -> Expectation) -> (() -> Expectation)
isInfiniteNormal expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "isInfinite") [ floatExpr 3.14 ])
        )



-- ============================================================================
-- INTEGER DIVISION BY ZERO (Gap 29)
-- ============================================================================


intDivZeroCases : (Src.Module -> Expectation) -> List TestCase
intDivZeroCases expectFn =
    [ { label = "10 // 0 returns 0", run = intDivByZero expectFn }
    , { label = "-5 // 0 returns 0", run = intDivByZeroNeg expectFn }
    ]


{-| 10 // 0 -> 0 (Elm semantics: integer division by zero returns 0)
-}
intDivByZero : (Src.Module -> Expectation) -> (() -> Expectation)
intDivByZero expectFn _ =
    expectFn
        (makeModule "testValue"
            (binopsExpr [ ( intExpr 10, "//" ) ] (intExpr 0))
        )


{-| -5 // 0 -> 0
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
-- LET-REC CLOSURE CAPTURING OUTER SCOPE (Gap 19)
-- ============================================================================


letRecCaptureCases : (Src.Module -> Expectation) -> List TestCase
letRecCaptureCases expectFn =
    [ { label = "Let-rec closure capturing outer scope", run = letRecCaptureOuterScope expectFn }
    ]


{-| processItems threshold items =
case items of
[] -> []
x :: rest ->
let takeMore xs = case xs of
[] -> []
y :: ys -> if y > threshold then y :: takeMore ys else []
in x :: takeMore rest

The inner `takeMore` captures `threshold` from outer scope and self-recurses.

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
