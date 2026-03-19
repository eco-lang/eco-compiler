module SourceIR.MutualRecTailRecCases exposing (expectSuite)

{-| Tests for mutual recursion, lambda boundary normalization, let-rec closure
capturing, nested tail-recursive definitions, and variable name collision
after inlining.

Covers gaps 8, 10, 19, 20, 11 from e2e-to-elmtest.md:
  - Top-level mutual recursion (non-trivial isEven/isOdd)
  - Lambda boundary normalization (case and let)
  - Let-rec closure capturing outer scope variable
  - Nested tail-recursive definitions
  - Variable name collision after inlining

-}

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
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mutual recursion and tail-rec gaps " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    mutualRecursionCases expectFn
        ++ lambdaBoundaryCases expectFn
        ++ letRecClosureCaptureCases expectFn
        ++ nestedTailRecCases expectFn
        ++ inlineVarCollisionCases expectFn



-- ============================================================================
-- TOP-LEVEL MUTUAL RECURSION (Gap 8)
-- ============================================================================


mutualRecursionCases : (Src.Module -> Expectation) -> List TestCase
mutualRecursionCases expectFn =
    [ { label = "Mutual recursion isEven/isOdd terminating", run = mutualRecIsEvenOdd expectFn }
    , { label = "Mutual recursion with different base cases", run = mutualRecDifferentBases expectFn }
    ]


{-| isEven 0 = True
isEven n = isOdd (n - 1)
isOdd 0 = False
isOdd n = isEven (n - 1)
testValue = isEven 4  =>  True
-}
mutualRecIsEvenOdd : (Src.Module -> Expectation) -> (() -> Expectation)
mutualRecIsEvenOdd expectFn _ =
    let
        intType =
            tType "Int" []

        boolType =
            tType "Bool" []

        isEvenDef : TypedDef
        isEvenDef =
            { name = "isEven"
            , args = [ pVar "n" ]
            , tipe = tLambda intType boolType
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (boolExpr True)
                    (callExpr (varExpr "isOdd")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
            }

        isOddDef : TypedDef
        isOddDef =
            { name = "isOdd"
            , args = [ pVar "n" ]
            , tipe = tLambda intType boolType
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (boolExpr False)
                    (callExpr (varExpr "isEven")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = boolType
            , body = callExpr (varExpr "isEven") [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ isEvenDef, isOddDef, testValueDef ]
    in
    expectFn modul


{-| Mutual recursion where both functions have different base values:
countDown 0 = 0
countDown n = countUp (n - 1)
countUp 0 = 100
countUp n = countDown (n - 1)
testValue = countDown 3
-}
mutualRecDifferentBases : (Src.Module -> Expectation) -> (() -> Expectation)
mutualRecDifferentBases expectFn _ =
    let
        intType =
            tType "Int" []

        countDownDef : TypedDef
        countDownDef =
            { name = "countDown"
            , args = [ pVar "n" ]
            , tipe = tLambda intType intType
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (intExpr 0)
                    (callExpr (varExpr "countUp")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
            }

        countUpDef : TypedDef
        countUpDef =
            { name = "countUp"
            , args = [ pVar "n" ]
            , tipe = tLambda intType intType
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (intExpr 100)
                    (callExpr (varExpr "countDown")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body = callExpr (varExpr "countDown") [ intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ countDownDef, countUpDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- LAMBDA BOUNDARY NORMALIZATION (Gap 10)
-- ============================================================================


lambdaBoundaryCases : (Src.Module -> Expectation) -> List TestCase
lambdaBoundaryCases expectFn =
    [ { label = "Lambda-case boundary: case returns lambdas", run = lambdaCaseBoundary expectFn }
    , { label = "Lambda-let boundary: let-separated staging", run = lambdaLetBoundary expectFn }
    ]


{-| getOp op = case op of
    0 -> \a b -> a + b
    _ -> \a b -> a - b
testValue = getOp 0 3 4  =>  7

Tests normalization: \op -> case op of 0 -> \a b -> a+b; _ -> \a b -> a-b
should become \op a b -> case op of 0 -> a+b; _ -> a-b
-}
lambdaCaseBoundary : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaCaseBoundary expectFn _ =
    let
        getOp =
            define "getOp"
                [ pVar "op" ]
                (caseExpr (varExpr "op")
                    [ ( pInt 0
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                      )
                    , ( pAnything
                      , lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b"))
                      )
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ getOp ]
                    (callExpr (varExpr "getOp") [ intExpr 0, intExpr 3, intExpr 4 ])
                )
    in
    expectFn modul


{-| f a = let y = a + 5 in \z -> y + z
testValue = f 10 20  =>  35

Tests normalization: \a -> let y = a+5 in \z -> y+z
should become \a z -> let y = a+5 in y+z
-}
lambdaLetBoundary : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaLetBoundary expectFn _ =
    let
        fDef =
            define "f"
                [ pVar "a" ]
                (letExpr
                    [ define "y" [] (binopsExpr [ ( varExpr "a", "+" ) ] (intExpr 5)) ]
                    (lambdaExpr [ pVar "z" ]
                        (binopsExpr [ ( varExpr "y", "+" ) ] (varExpr "z"))
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ fDef ]
                    (callExpr (varExpr "f") [ intExpr 10, intExpr 20 ])
                )
    in
    expectFn modul



-- ============================================================================
-- LET-REC CLOSURE CAPTURING OUTER SCOPE (Gap 19)
-- ============================================================================


letRecClosureCaptureCases : (Src.Module -> Expectation) -> List TestCase
letRecClosureCaptureCases expectFn =
    [ { label = "Let-rec captures outer variable (takeItems pattern)", run = letRecCaptureOuter expectFn }
    , { label = "Let-rec captures outer param and recurses", run = letRecCaptureOuterParam expectFn }
    ]


{-| processItems threshold items = case items of
    [] -> []
    x :: rest ->
        let
            takeMore xs = case xs of
                [] -> []
                y :: ys -> if y > threshold then y :: takeMore ys else []
        in
        x :: takeMore rest

takeMore captures `threshold` from outer scope and self-recurses.
-}
letRecCaptureOuter : (Src.Module -> Expectation) -> (() -> Expectation)
letRecCaptureOuter expectFn _ =
    let
        takeMoreBody =
            caseExpr (varExpr "xs")
                [ ( pList [], listExpr [] )
                , ( pCons (pVar "y") (pVar "ys")
                  , ifExpr
                        (binopsExpr [ ( varExpr "y", ">" ) ] (varExpr "threshold"))
                        (binopsExpr [ ( varExpr "y", "::" ) ] (callExpr (varExpr "takeMore") [ varExpr "ys" ]))
                        (listExpr [])
                  )
                ]

        takeMore =
            define "takeMore" [ pVar "xs" ] takeMoreBody

        processBody =
            caseExpr (varExpr "items")
                [ ( pList [], listExpr [] )
                , ( pCons (pVar "x") (pVar "rest")
                  , letExpr [ takeMore ]
                        (binopsExpr [ ( varExpr "x", "::" ) ] (callExpr (varExpr "takeMore") [ varExpr "rest" ]))
                  )
                ]

        processItems =
            define "processItems" [ pVar "threshold", pVar "items" ] processBody

        modul =
            makeModule "testValue"
                (letExpr [ processItems ]
                    (callExpr (varExpr "processItems")
                        [ intExpr 3
                        , listExpr [ intExpr 5, intExpr 4, intExpr 2, intExpr 6 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| filterAbove limit xs =
    let
        go items = case items of
            [] -> []
            h :: t -> if h > limit then h :: go t else go t
    in
    go xs
testValue = filterAbove 2 [1, 3, 2, 4]  =>  [3, 4]

`go` captures `limit` from outer scope.
-}
letRecCaptureOuterParam : (Src.Module -> Expectation) -> (() -> Expectation)
letRecCaptureOuterParam expectFn _ =
    let
        goBody =
            caseExpr (varExpr "items")
                [ ( pList [], listExpr [] )
                , ( pCons (pVar "h") (pVar "t")
                  , ifExpr
                        (binopsExpr [ ( varExpr "h", ">" ) ] (varExpr "limit"))
                        (binopsExpr [ ( varExpr "h", "::" ) ] (callExpr (varExpr "go") [ varExpr "t" ]))
                        (callExpr (varExpr "go") [ varExpr "t" ])
                  )
                ]

        filterAbove =
            define "filterAbove"
                [ pVar "limit", pVar "xs" ]
                (letExpr [ define "go" [ pVar "items" ] goBody ]
                    (callExpr (varExpr "go") [ varExpr "xs" ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ filterAbove ]
                    (callExpr (varExpr "filterAbove")
                        [ intExpr 2
                        , listExpr [ intExpr 1, intExpr 3, intExpr 2, intExpr 4 ]
                        ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- NESTED TAIL-RECURSIVE DEFINITIONS (Gap 20)
-- ============================================================================


nestedTailRecCases : (Src.Module -> Expectation) -> List TestCase
nestedTailRecCases expectFn =
    [ { label = "Outer tail-rec with inner tail-rec def", run = outerTailRecWithInner expectFn }
    , { label = "Two nested tail-rec defs in sequence", run = twoNestedTailRecs expectFn }
    ]


{-| outerLoop n acc =
    let
        sumUpTo i s = if i <= 0 then s else sumUpTo (i - 1) (s + i)
        localResult = sumUpTo n 0
    in
    case localResult of
        0 -> acc
        _ -> outerLoop (n - 1) (acc + localResult)
testValue = outerLoop 3 0
Both outerLoop and sumUpTo are tail-recursive.
-}
outerTailRecWithInner : (Src.Module -> Expectation) -> (() -> Expectation)
outerTailRecWithInner expectFn _ =
    let
        intType =
            tType "Int" []

        sumUpToBody =
            ifExpr
                (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                (varExpr "s")
                (callExpr (varExpr "sumUpTo")
                    [ binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)
                    , binopsExpr [ ( varExpr "s", "+" ) ] (varExpr "i")
                    ]
                )

        outerBody =
            letExpr
                [ define "sumUpTo" [ pVar "i", pVar "s" ] sumUpToBody
                , define "localResult" [] (callExpr (varExpr "sumUpTo") [ varExpr "n", intExpr 0 ])
                ]
                (caseExpr (varExpr "localResult")
                    [ ( pInt 0, varExpr "acc" )
                    , ( pAnything
                      , callExpr (varExpr "outerLoop")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                            , binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "localResult")
                            ]
                      )
                    ]
                )

        outerLoopDef : TypedDef
        outerLoopDef =
            { name = "outerLoop"
            , args = [ pVar "n", pVar "acc" ]
            , tipe = tLambda intType (tLambda intType intType)
            , body = outerBody
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body = callExpr (varExpr "outerLoop") [ intExpr 3, intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ outerLoopDef, testValueDef ]
    in
    expectFn modul


{-| process n =
    let
        sumTo i acc = if i <= 0 then acc else sumTo (i - 1) (acc + i)
        mulTo i acc = if i <= 0 then acc else mulTo (i - 1) (acc * i)
    in
    sumTo n 0 + mulTo n 1
testValue = process 4
Two local tail-recursive defs in the same let block.
-}
twoNestedTailRecs : (Src.Module -> Expectation) -> (() -> Expectation)
twoNestedTailRecs expectFn _ =
    let
        intType =
            tType "Int" []

        sumToBody =
            ifExpr
                (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                (varExpr "acc")
                (callExpr (varExpr "sumTo")
                    [ binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)
                    , binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "i")
                    ]
                )

        mulToBody =
            ifExpr
                (binopsExpr [ ( varExpr "j", "<=" ) ] (intExpr 0))
                (varExpr "acc2")
                (callExpr (varExpr "mulTo")
                    [ binopsExpr [ ( varExpr "j", "-" ) ] (intExpr 1)
                    , binopsExpr [ ( varExpr "acc2", "*" ) ] (varExpr "j")
                    ]
                )

        processBody =
            letExpr
                [ define "sumTo" [ pVar "i", pVar "acc" ] sumToBody
                , define "mulTo" [ pVar "j", pVar "acc2" ] mulToBody
                ]
                (binopsExpr
                    [ ( callExpr (varExpr "sumTo") [ varExpr "n", intExpr 0 ], "+" ) ]
                    (callExpr (varExpr "mulTo") [ varExpr "n", intExpr 1 ])
                )

        processDef : TypedDef
        processDef =
            { name = "process"
            , args = [ pVar "n" ]
            , tipe = tLambda intType intType
            , body = processBody
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body = callExpr (varExpr "process") [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ processDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- VARIABLE NAME COLLISION AFTER INLINING (Gap 11)
-- ============================================================================


inlineVarCollisionCases : (Src.Module -> Expectation) -> List TestCase
inlineVarCollisionCases expectFn =
    [ { label = "Inline var collision: extract called twice", run = inlineVarCollisionExtract expectFn }
    , { label = "Inline var collision: nested destructuring", run = inlineVarCollisionNested expectFn }
    ]


{-| type Wrapped = Wrapped Int
extract (Wrapped n) = n
useTwice w = extract w + extract w
testValue = useTwice (Wrapped 21)  =>  42

After inlining first `extract` call, the destructured "n" must not shadow
the "n" from the second `extract` call.
-}
inlineVarCollisionExtract : (Src.Module -> Expectation) -> (() -> Expectation)
inlineVarCollisionExtract expectFn _ =
    let
        wrappedUnion : UnionDef
        wrappedUnion =
            { name = "Wrapped"
            , args = []
            , ctors =
                [ { name = "Wrapped", args = [ tType "Int" [] ] }
                ]
            }

        intType =
            tType "Int" []

        extractDef : TypedDef
        extractDef =
            { name = "extract"
            , args = [ pCtor "Wrapped" [ pVar "n" ] ]
            , tipe = tLambda (tType "Wrapped" []) intType
            , body = varExpr "n"
            }

        useTwiceDef : TypedDef
        useTwiceDef =
            { name = "useTwice"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrapped" []) intType
            , body =
                binopsExpr
                    [ ( callExpr (varExpr "extract") [ varExpr "w" ], "+" ) ]
                    (callExpr (varExpr "extract") [ varExpr "w" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body = callExpr (varExpr "useTwice") [ callExpr (ctorExpr "Wrapped") [ intExpr 21 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractDef, useTwiceDef, testValueDef ]
                [ wrappedUnion ]
                []
    in
    expectFn modul


{-| type Box = Box Int
getVal (Box v) = v
helper a b = a + b
combine box1 box2 = helper (getVal box1) (getVal box2)
testValue = combine (Box 10) (Box 32)  =>  42

When both getVal calls are inlined, both produce a destructured "v".
Tests that MonoInlineSimplify renames to avoid collision.
-}
inlineVarCollisionNested : (Src.Module -> Expectation) -> (() -> Expectation)
inlineVarCollisionNested expectFn _ =
    let
        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Box", args = [ tType "Int" [] ] }
                ]
            }

        intType =
            tType "Int" []

        getValDef : TypedDef
        getValDef =
            { name = "getVal"
            , args = [ pCtor "Box" [ pVar "v" ] ]
            , tipe = tLambda (tType "Box" []) intType
            , body = varExpr "v"
            }

        helperDef : TypedDef
        helperDef =
            { name = "helper"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda intType (tLambda intType intType)
            , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
            }

        combineDef : TypedDef
        combineDef =
            { name = "combine"
            , args = [ pVar "box1", pVar "box2" ]
            , tipe = tLambda (tType "Box" []) (tLambda (tType "Box" []) intType)
            , body =
                callExpr (varExpr "helper")
                    [ callExpr (varExpr "getVal") [ varExpr "box1" ]
                    , callExpr (varExpr "getVal") [ varExpr "box2" ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = intType
            , body =
                callExpr (varExpr "combine")
                    [ callExpr (ctorExpr "Box") [ intExpr 10 ]
                    , callExpr (ctorExpr "Box") [ intExpr 32 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getValDef, helperDef, combineDef, testValueDef ]
                [ boxUnion ]
                []
    in
    expectFn modul
