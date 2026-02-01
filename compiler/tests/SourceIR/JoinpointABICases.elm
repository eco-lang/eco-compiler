module SourceIR.JoinpointABICases exposing (expectSuite, suite, testCases)

{-| Test cases for join-point ABI coercion in MonoCase expressions.

These tests cover the canonical segmentation selection and ABI wrapper
generation when case branches return functions with different staging:

  - Category 1: Identical staging (no wrappers needed)
  - Category 2: Different stagings (majority wins)
  - Category 3: Tie-breaking (prefer flatter)
  - Category 4: Nested control flow (inner stages separated)
  - Category 5: Edge cases

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , pAnything
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
        , pInt
        , pList
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import TestLogic.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.test "JoinpointABI coverage monomorphizes case branches" <|
        \_ -> bulkCheck (testCases expectMonomorphization)


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("JoinpointABI " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


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
-- CATEGORY 1: IDENTICAL STAGING (NO WRAPPERS NEEDED)
-- ============================================================================


identicalStagingCases : (Src.Module -> Expectation) -> List TestCase
identicalStagingCases expectFn =
    [ { label = "1.1 identicalFlat2", run = identicalFlat2 expectFn }
    , { label = "1.2 identicalCurried11", run = identicalCurried11 expectFn }
    , { label = "1.3 identicalFlat3", run = identicalFlat3 expectFn }
    , { label = "1.4 identicalCurried111", run = identicalCurried111 expectFn }
    , { label = "1.5 identicalMixed21", run = identicalMixed21 expectFn }
    , { label = "1.6 nonFunctionBranches", run = nonFunctionBranches expectFn }
    ]


{-| All branches return flat binary function: \a b -> expr
Segmentation: all [2]
-}
identicalFlat2 : (Src.Module -> Expectation) -> (() -> Expectation)
identicalFlat2 expectFn _ =
    let
        -- caseFunc : Int -> Int -> Int -> Int
        -- caseFunc x a b = case x of
        --     0 -> a + b
        --     _ -> a - b
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


{-| All branches return curried unary functions: \a -> \b -> expr
Segmentation: all [1,1]
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


{-| All branches return flat ternary function: \a b c -> expr
Segmentation: all [3]
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


{-| All branches return deeply curried: \a -> \b -> \c -> expr
Segmentation: all [1,1,1]
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


{-| All branches return mixed staging: \a b -> \c -> expr
Segmentation: all [2,1]
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


{-| All branches return non-function values (Int).
No function leaves, no coercion needed.
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
-- CATEGORY 2: DIFFERENT STAGINGS (MAJORITY WINS)
-- ============================================================================


majorityStagingCases : (Src.Module -> Expectation) -> List TestCase
majorityStagingCases expectFn =
    [ { label = "2.1 majority2Flat", run = majority2Flat expectFn }
    , { label = "2.2 majority2Curried", run = majority2Curried expectFn }
    , { label = "2.3 majority3Flat", run = majority3Flat expectFn }
    , { label = "2.4 majorityMixed", run = majorityMixed expectFn }
    ]


{-| 2 flat [2], 1 curried [1,1] -> canonical [2]
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


{-| 1 flat [2], 2 curried [1,1] -> canonical [1,1]
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


{-| 3 flat [3], 1 curried [1,1,1] -> canonical [3]
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


{-| 2x[2,1], 1x[1,2], 1x[3] -> canonical [2,1]
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
                      , -- [2,1]: \a b -> \c -> ...
                        lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                            )
                      )
                    , ( pInt 1
                      , -- [2,1]: \a b -> \c -> ...
                        lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                            )
                      )
                    , ( pInt 2
                      , -- [1,2]: \a -> \b c -> ...
                        lambdaExpr [ pVar "a" ]
                            (lambdaExpr [ pVar "b", pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "*" ), ( varExpr "b", "*" ) ] (varExpr "c"))
                            )
                      )
                    , ( pAnything
                      , -- [3]: \a b c -> ...
                        lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
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
-- CATEGORY 3: TIE-BREAKING (PREFER FLATTER)
-- ============================================================================


tieBreakingCases : (Src.Module -> Expectation) -> List TestCase
tieBreakingCases expectFn =
    [ { label = "3.1 tieBreakBinary", run = tieBreakBinary expectFn }
    , { label = "3.2 tieBreakTernary", run = tieBreakTernary expectFn }
    , { label = "3.3 tieBreakQuaternary", run = tieBreakQuaternary expectFn }
    , { label = "3.4 tieEqualDepth", run = tieEqualDepth expectFn }
    ]


{-| 1 flat [2], 1 curried [1,1] (equal count) -> canonical [2] (fewer stages)
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


{-| 1x[3], 1x[2,1], 1x[1,1,1] -> canonical [3] (1 stage vs 2 vs 3)
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
                      , -- [3]: \a b c -> ...
                        lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                      )
                    , ( pInt 1
                      , -- [2,1]: \a b -> \c -> ...
                        lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ) ] (varExpr "c"))
                            )
                      )
                    , ( pAnything
                      , -- [1,1,1]: \a -> \b -> \c -> ...
                        lambdaExpr [ pVar "a" ]
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


{-| 1x[4], 1x[2,2], 1x[1,1,1,1] -> canonical [4] (flattest)
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
                      , -- [4]: \a b c d -> ...
                        lambdaExpr [ pVar "a", pVar "b", pVar "c", pVar "d" ]
                            (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ), ( varExpr "c", "+" ) ] (varExpr "d"))
                      )
                    , ( pInt 1
                      , -- [2,2]: \a b -> \c d -> ...
                        lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c", pVar "d" ]
                                (binopsExpr [ ( varExpr "a", "-" ), ( varExpr "b", "-" ), ( varExpr "c", "-" ) ] (varExpr "d"))
                            )
                      )
                    , ( pAnything
                      , -- [1,1,1,1]: \a -> \b -> \c -> \d -> ...
                        lambdaExpr [ pVar "a" ]
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


{-| 1x[2,1], 1x[1,2] (both 2 stages) -> either valid (implementation-defined)
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
                      , -- [2,1]: \a b -> \c -> ...
                        lambdaExpr [ pVar "a", pVar "b" ]
                            (lambdaExpr [ pVar "c" ]
                                (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                            )
                      )
                    , ( pAnything
                      , -- [1,2]: \a -> \b c -> ...
                        lambdaExpr [ pVar "a" ]
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
-- CATEGORY 4: NESTED CONTROL FLOW (INNER STAGES SEPARATED)
-- ============================================================================


nestedControlFlowCases : (Src.Module -> Expectation) -> List TestCase
nestedControlFlowCases expectFn =
    [ { label = "4.1 nestedCaseInBranch", run = nestedCaseInBranch expectFn }
    , { label = "4.2 ifInCaseBranch", run = ifInCaseBranch expectFn }
    , { label = "4.3 letFunctionInBranch", run = letFunctionInBranch expectFn }
    , { label = "4.4 letSeparatedStaging", run = letSeparatedStaging expectFn }
    , { label = "4.5 deeplyNestedControl", run = deeplyNestedControl expectFn }
    , { label = "4.6 caseInBothBranches", run = caseInBothBranches expectFn }
    ]


{-| Outer case with inner case in one branch.
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


{-| Nested case inside outer case branch (variant of 4.1 with different structure).
-}
ifInCaseBranch : (Src.Module -> Expectation) -> (() -> Expectation)
ifInCaseBranch expectFn _ =
    let
        caseFuncDef : TypedDef
        caseFuncDef =
            { name = "caseFunc"
            , args = [ pVar "n", pVar "m" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0
                      , caseExpr (varExpr "m")
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


{-| let binding function in branch.
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


{-| let creates separated staging [1,1] vs flat [2].
\a -> let y = ... in \z -> ... creates [1,1]
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
                      , -- [1,1]: \a -> let y = a + k in \z -> y + z
                        lambdaExpr [ pVar "a" ]
                            (letExpr
                                [ define "y" [] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "k"))
                                ]
                                (lambdaExpr [ pVar "z" ]
                                    (binopsExpr [ ( varExpr "y", "+" ) ] (varExpr "z"))
                                )
                            )
                      )
                    , ( pAnything
                      , -- [2]: \a z -> a + z
                        lambdaExpr [ pVar "a", pVar "z" ]
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


{-| Multiple levels: case -> case -> let -> lambda.
Tests staging preservation through nesting.
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


{-| Inner case expressions in multiple branches.
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


edgeCases : (Src.Module -> Expectation) -> List TestCase
edgeCases expectFn =
    [ { label = "5.2 wildcardOnlyCase", run = wildcardOnlyCase expectFn }
    , { label = "5.3 highArityFunction", run = highArityFunction expectFn }
    , { label = "5.4 recordPatternBranches", run = recordPatternBranches expectFn }
    , { label = "5.5 customTypeBranches", run = customTypeBranches expectFn }
    , { label = "5.6 listPatternBranches", run = listPatternBranches expectFn }
    ]


{-| Case with only wildcard pattern.
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


{-| 5+ argument functions with varied staging.
Test [5], [3,2], [2,2,1], [1,1,1,1,1]
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
                      , -- [5]: \a b c d e -> ...
                        lambdaExpr [ pVar "a", pVar "b", pVar "c", pVar "d", pVar "e" ]
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
                      , -- [3,2]: \a b c -> \d e -> ...
                        lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
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
                      , -- [2,2,1]: \a b -> \c d -> \e -> ...
                        lambdaExpr [ pVar "a", pVar "b" ]
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
                      , -- [1,1,1,1,1]: \a -> \b -> \c -> \d -> \e -> ...
                        lambdaExpr [ pVar "a" ]
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


{-| Case on Int with function-returning branches.
Different staging demonstrates join-point ABI coercion.
-}
recordPatternBranches : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternBranches expectFn _ =
    let
        -- Use Int to select between branches, returning functions
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
                      , -- [2]: \x y -> ...
                        lambdaExpr [ pVar "x", pVar "y" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
                      )
                    , ( pAnything
                      , -- [1,1]: \x -> \y -> ...
                        lambdaExpr [ pVar "x" ]
                            (lambdaExpr [ pVar "y" ]
                                (binopsExpr [ ( varExpr "x", "-" ) ] (varExpr "y"))
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


{-| Case on custom type (Maybe-like) with function-returning branches.
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


{-| Case on list structure with function-returning branches.
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
