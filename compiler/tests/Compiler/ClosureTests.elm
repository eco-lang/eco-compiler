module Compiler.ClosureTests exposing (expectSuite, suite, testCases)

{-| Test cases for closure handling in Monomorphize.

These tests cover:

  - Monomorphize.Closure.extractRegion (12% coverage)
  - Monomorphize.Closure.findFreeLocals (85% coverage)
  - Simple closures capturing local variables
  - Nested closures
  - Closures in case expressions
  - Closures capturing records and tuples

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessExpr
        , binopsExpr
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
        , pCons
        , pCtor
        , pList
        , pTuple
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.test "Closure handling coverage monomorphizes closures" <|
        \_ -> bulkCheck (testCases expectMonomorphization)


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Closure handling " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ simpleClosureCases expectFn
        , nestedClosureCases expectFn
        , closureInCaseCases expectFn
        , closureCapturingTypesCases expectFn
        , closureWithRecursionCases expectFn
        ]



-- ============================================================================
-- SIMPLE CLOSURE TESTS
-- ============================================================================


simpleClosureCases : (Src.Module -> Expectation) -> List TestCase
simpleClosureCases expectFn =
    [ { label = "Closure over single local", run = closureOverSingleLocal expectFn }
    , { label = "Closure over two locals", run = closureOverTwoLocals expectFn }
    , { label = "Closure in let binding", run = closureInLetBinding expectFn }
    , { label = "Closure as return value", run = closureAsReturnValue expectFn }
    , { label = "Closure applied immediately", run = closureAppliedImmediately expectFn }
    ]


{-| Test closure capturing a single local variable.
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


{-| Test closure capturing two local variables.
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


{-| Test closure defined in let binding.
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


{-| Test function returning a closure.
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


{-| Test closure applied immediately.
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


nestedClosureCases : (Src.Module -> Expectation) -> List TestCase
nestedClosureCases expectFn =
    [ { label = "Double nested closure", run = doubleNestedClosure expectFn }
    , { label = "Closure returning closure", run = closureReturningClosure expectFn }
    , { label = "Nested let closures", run = nestedLetClosures expectFn }
    , { label = "Triple nested closure", run = tripleNestedClosure expectFn }
    ]


{-| Test double nested closure.
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


{-| Test closure returning another closure.
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


{-| Test nested let bindings with closures.
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


{-| Test triple nested closure.
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


closureInCaseCases : (Src.Module -> Expectation) -> List TestCase
closureInCaseCases expectFn =
    [ { label = "Closure in case branch", run = closureInCaseBranch expectFn }
    , { label = "Different closures per branch", run = differentClosuresPerBranch expectFn }
    , { label = "Closure capturing scrutinee", run = closureCapturingScrutinee expectFn }
    , { label = "Closure in Maybe case", run = closureInMaybeCase expectFn }
    ]


{-| Test closure defined in case branch.
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


{-| Test different closures in different branches.
-}
differentClosuresPerBranch : (Src.Module -> Expectation) -> (() -> Expectation)
differentClosuresPerBranch expectFn _ =
    let
        -- opClosure : Int -> (Int -> Int)
        -- opClosure op =
        --     case op of
        --         0 -> \x -> x + 1
        --         1 -> \x -> x * 2
        --         _ -> \x -> x
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


{-| Test closure capturing value from scrutinee binding.
-}
closureCapturingScrutinee : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingScrutinee expectFn _ =
    let
        -- captureScrutinee : List Int -> (Int -> Int)
        -- captureScrutinee xs =
        --     case xs of
        --         [] -> \x -> x
        --         h :: _ -> \x -> x + h
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


{-| Test closure in Maybe case with both branches.
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


closureCapturingTypesCases : (Src.Module -> Expectation) -> List TestCase
closureCapturingTypesCases expectFn =
    [ { label = "Closure capturing record", run = closureCapturingRecord expectFn }
    , { label = "Closure capturing tuple", run = closureCapturingTuple expectFn }
    , { label = "Closure capturing list head", run = closureCapturingListHead expectFn }
    , { label = "Closure capturing multiple types", run = closureCapturingMultipleTypes expectFn }
    ]


{-| Test closure capturing a record.
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


{-| Test closure capturing a tuple.
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


{-| Test closure capturing list head.
-}
closureCapturingListHead : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingListHead expectFn _ =
    let
        -- closureFromList : List Int -> (Int -> Int)
        -- closureFromList xs =
        --     case xs of
        --         [] -> \x -> x
        --         h :: _ -> \x -> x * h
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


{-| Test closure capturing multiple different types.
-}
closureCapturingMultipleTypes : (Src.Module -> Expectation) -> (() -> Expectation)
closureCapturingMultipleTypes expectFn _ =
    let
        -- multiCapture : Int -> List Int -> (Int -> Int)
        -- multiCapture base xs =
        --     case xs of
        --         [] -> \x -> x + base
        --         h :: _ -> \x -> x + base + h
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


closureWithRecursionCases : (Src.Module -> Expectation) -> List TestCase
closureWithRecursionCases expectFn =
    [ { label = "Closure in recursive function", run = closureInRecursiveFunction expectFn }
    , { label = "Recursive closure", run = recursiveClosure expectFn }
    , { label = "Closure with tail recursion", run = closureWithTailRecursion expectFn }
    ]


{-| Test closure used in recursive function.
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


{-| Test recursive closure.
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


{-| Test closure with tail recursion.
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
