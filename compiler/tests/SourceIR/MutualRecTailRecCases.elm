module SourceIR.MutualRecTailRecCases exposing (expectSuite)

{-| Supplies test programs in which functions call one another, return
functions, or are defined locally and recurse, so that the checks of a pipeline
stage are run against these shapes and not only against simpler programs.

This module asserts nothing itself. `expectSuite` hands the programs, in order,
to the expectation function its caller passes, stopping at the first that
fails, so what is checked depends on that function.

Each program is one module named `Test` with a top-level `testValue`. The
mutual-recursion, nested tail-recursion and inlining programs declare their
functions at top level, each with a type annotation. The lambda-boundary and
local-recursion programs declare only `testValue`, unannotated, and bind the
functions under test in its `let`.

The cases, in the order they run:

  - Mutual recursion: two top-level functions that call each other, as
    `isEven` and `isOdd`, and as a pair whose base cases return different
    values.
  - Lambda boundaries: a function that returns a lambda from each branch of a
    `case`, and one that returns a lambda after a `let`. In both, the
    function's parameters are split between the outer definition and the
    returned lambda. These are the two shapes that
    `Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries` rewrites, where it can,
    by moving the inner lambda's parameters onto the outer function.
  - Local recursion that captures: a `let`-bound recursive function that reads
    a parameter of the function enclosing it, in two programs.
  - Nested tail recursion: a tail-recursive local function inside a function
    that is itself tail-recursive, and two tail-recursive local functions side
    by side in one `let`.
  - Inlining collisions: a function that destructures its argument into a
    named variable, called twice in one expression, so that copying both calls'
    bodies into the caller would bind the same name twice.

Among what is not tested: mutual recursion between `let`-bound functions,
recursion through a value with no arguments, and `case` branches that return
lambdas of different arities. The value each program computes is not checked
here; the results given in each case's docstring are what the program evaluates
to.

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
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named `"Mutual recursion and tail-rec gaps "` followed by
`condStr`, that runs the cases in order through `Compiler.BulkCheck.bulkCheck`,
applying `expectFn` to each case's module. It passes if every case passes. The
first failing case stops the run, and the test fails with that case's label and
failure description; a case that crashes ends the test without its label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mutual recursion and tail-rec gaps " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in the module, group by group, each checking its program
with `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    mutualRecursionCases expectFn
        ++ lambdaBoundaryCases expectFn
        ++ letRecClosureCaptureCases expectFn
        ++ nestedTailRecCases expectFn
        ++ inlineVarCollisionCases expectFn



-- ============================================================================
-- TOP-LEVEL MUTUAL RECURSION
-- ============================================================================


{-| Returns the two mutual-recursion cases, each checking its program with
`expectFn`.
-}
mutualRecursionCases : (Src.Module -> Expectation) -> List TestCase
mutualRecursionCases expectFn =
    [ { label = "Mutual recursion isEven/isOdd terminating", run = mutualRecIsEvenOdd expectFn }
    , { label = "Mutual recursion with different base cases", run = mutualRecDifferentBases expectFn }
    ]


{-| Builds a module in which `isEven` and `isOdd` call each other, and applies
`expectFn` to it:

    isEven : Int -> Bool
    isEven n =
        if n == 0 then
            True

        else
            isOdd (n - 1)

    isOdd : Int -> Bool
    isOdd n =
        if n == 0 then
            False

        else
            isEven (n - 1)

    testValue : Bool
    testValue =
        isEven 4

`testValue` is `True`.

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


{-| Builds a module in which `countDown` and `countUp` call each other but
return different values at zero, and applies `expectFn` to it:

    countDown : Int -> Int
    countDown n =
        if n == 0 then
            0

        else
            countUp (n - 1)

    countUp : Int -> Int
    countUp n =
        if n == 0 then
            100

        else
            countDown (n - 1)

    testValue : Int
    testValue =
        countDown 3

The recursion ends in `countUp`, so `testValue` is 100.

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
-- LAMBDA BOUNDARY NORMALIZATION
-- ============================================================================


{-| Returns the two lambda-boundary cases, each checking its program with
`expectFn`.
-}
lambdaBoundaryCases : (Src.Module -> Expectation) -> List TestCase
lambdaBoundaryCases expectFn =
    [ { label = "Lambda-case boundary: case returns lambdas", run = lambdaCaseBoundary expectFn }
    , { label = "Lambda-let boundary: let-separated staging", run = lambdaLetBoundary expectFn }
    ]


{-| Builds a module whose `testValue` defines a local `getOp` that returns a
two-argument lambda from each branch of a `case`, and applies `expectFn` to it:

    testValue =
        let
            getOp op =
                case op of
                    0 ->
                        \a b -> a + b

                    _ ->
                        \a b -> a - b
        in
        getOp 0 3 4

`getOp` takes one parameter and is called with three. `testValue` is 7.

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


{-| Builds a module whose `testValue` defines a local `f` that returns a lambda
after a `let`, and applies `expectFn` to it:

    testValue =
        let
            f a =
                let
                    y =
                        a + 5
                in
                \z -> y + z
        in
        f 10 20

`f` takes one parameter and is called with two. `testValue` is 35.

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
-- LET-REC CLOSURE CAPTURING OUTER SCOPE
-- ============================================================================


{-| Returns the two cases of a local recursive function that captures a
parameter of its enclosing function, each checking its program with `expectFn`.
-}
letRecClosureCaptureCases : (Src.Module -> Expectation) -> List TestCase
letRecClosureCaptureCases expectFn =
    [ { label = "Let-rec captures outer variable (takeItems pattern)", run = letRecCaptureOuter expectFn }
    , { label = "Let-rec captures outer param and recurses", run = letRecCaptureOuterParam expectFn }
    ]


{-| Builds a module whose `testValue` defines a local `processItems`, inside
which a recursive `takeMore` reads `processItems`'s parameter `threshold`, and
applies `expectFn` to it:

    testValue =
        let
            processItems threshold items =
                case items of
                    [] ->
                        []

                    x :: rest ->
                        let
                            takeMore xs =
                                case xs of
                                    [] ->
                                        []

                                    y :: ys ->
                                        if y > threshold then
                                            y :: takeMore ys

                                        else
                                            []
                        in
                        x :: takeMore rest
        in
        processItems 3 [ 5, 4, 2, 6 ]

`takeMore`'s recursive call is not in tail position. `testValue` is `[ 5, 4 ]`.

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


{-| Builds a module whose `testValue` defines a local `filterAbove`, inside
which a recursive `go` reads `filterAbove`'s parameter `limit`, and applies
`expectFn` to it:

    testValue =
        let
            filterAbove limit xs =
                let
                    go items =
                        case items of
                            [] ->
                                []

                            h :: t ->
                                if h > limit then
                                    h :: go t

                                else
                                    go t
                in
                go xs
        in
        filterAbove 2 [ 1, 3, 2, 4 ]

`go` calls itself in tail position in one branch and not in the other.
`testValue` is `[ 3, 4 ]`.

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
-- NESTED TAIL-RECURSIVE DEFINITIONS
-- ============================================================================


{-| Returns the two nested tail-recursion cases, each checking its program with
`expectFn`.
-}
nestedTailRecCases : (Src.Module -> Expectation) -> List TestCase
nestedTailRecCases expectFn =
    [ { label = "Outer tail-rec with inner tail-rec def", run = outerTailRecWithInner expectFn }
    , { label = "Two nested tail-rec defs in sequence", run = twoNestedTailRecs expectFn }
    ]


{-| Builds a module in which the tail-recursive `outerLoop` defines its own
tail-recursive `sumUpTo` in a `let`, and applies `expectFn` to it:

    outerLoop : Int -> Int -> Int
    outerLoop n acc =
        let
            sumUpTo i s =
                if i <= 0 then
                    s

                else
                    sumUpTo (i - 1) (s + i)

            localResult =
                sumUpTo n 0
        in
        case localResult of
            0 ->
                acc

            _ ->
                outerLoop (n - 1) (acc + localResult)

    testValue : Int
    testValue =
        outerLoop 3 0

`testValue` is 10, the sum of 6, 3 and 1.

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


{-| Builds a module in which `process` defines two tail-recursive functions in
one `let` and adds their results, and applies `expectFn` to it:

    process : Int -> Int
    process n =
        let
            sumTo i acc =
                if i <= 0 then
                    acc

                else
                    sumTo (i - 1) (acc + i)

            mulTo j acc2 =
                if j <= 0 then
                    acc2

                else
                    mulTo (j - 1) (acc2 * j)
        in
        sumTo n 0 + mulTo n 1

    testValue : Int
    testValue =
        process 4

`testValue` is 34, which is 10 + 24.

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
-- VARIABLE NAME COLLISION AFTER INLINING
-- ============================================================================


{-| Returns the two inlining-collision cases, each checking its program with
`expectFn`.
-}
inlineVarCollisionCases : (Src.Module -> Expectation) -> List TestCase
inlineVarCollisionCases expectFn =
    [ { label = "Inline var collision: extract called twice", run = inlineVarCollisionExtract expectFn }
    , { label = "Inline var collision: nested destructuring", run = inlineVarCollisionNested expectFn }
    ]


{-| Builds a module in which `useTwice` calls `extract` twice on the same value,
and applies `expectFn` to it:

    type Wrapped
        = Wrapped Int

    extract : Wrapped -> Int
    extract (Wrapped n) =
        n

    useTwice : Wrapped -> Int
    useTwice w =
        extract w + extract w

    testValue : Int
    testValue =
        useTwice (Wrapped 21)

Copying `extract`'s body into `useTwice` at both calls brings two bindings
named `n` into one expression. `testValue` is 42.

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


{-| Builds a module in which `combine` passes the results of two `getVal` calls
as the arguments of a third function, and applies `expectFn` to it:

    type Box
        = Box Int

    getVal : Box -> Int
    getVal (Box v) =
        v

    helper : Int -> Int -> Int
    helper a b =
        a + b

    combine : Box -> Box -> Int
    combine box1 box2 =
        helper (getVal box1) (getVal box2)

    testValue : Int
    testValue =
        combine (Box 10) (Box 32)

Copying `getVal`'s body into `combine` at both calls brings two bindings named
`v` into one expression. Nothing is destructured more than one level deep,
despite the case's label. `testValue` is 42.

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
