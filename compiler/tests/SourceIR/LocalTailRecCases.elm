module SourceIR.LocalTailRecCases exposing (expectSuite)

{-| Programs with tail-recursive functions defined inside a `let`, so that a
pipeline-stage check can be run against them.

A function defined in a `let` whose body calls itself in tail position is kept
by the typed optimizer as a tail definition rather than an ordinary one, and it
reaches monomorphization as a `MonoTailDef`, whose parameters each carry their
own type. That is a different shape from a top-level tail-recursive function
(`MonoTailFunc`), so a stage can handle one correctly and the other not. These
programs put local tail definitions in four positions: alone, beside another,
capturing a variable from the enclosing function, and inside another recursive
function.

This module asserts nothing itself. `expectSuite` hands each program, as a
`Src.Module`, to the expectation function its caller supplies, and that function
decides what is checked.

No local function in these programs is annotated. Three programs are built with
`makeModule`, which annotates nothing, so their integer literals and arithmetic
have the type `number`, not `Int`. The other two are built with
`makeModuleWithTypedDefs`, and their top-level functions have annotations built
from `Int`.

The cases, in the order they run:

  - A single local tail-recursive `sumUpTo` summing the integers from 10 down to
    1, in an unannotated `testValue`.
  - The same local `sumUpTo` inside `outerLoop : Int -> Int -> Int`, which is
    itself tail-recursive.
  - A local tail-recursive `loop` inside `process : Int -> Int` that captures
    `process`'s argument `x`.
  - Two local tail-recursive functions, `countDown` and `sumUp`, in one `let`,
    both called in its body.
  - A local tail-recursive `inner` inside the body of a local `outer` that is
    itself tail-recursive.

Among what is not tested: a local tail-recursive function whose parameters or
result are anything other than numbers, a local tail-recursive function that is
passed as a value rather than called, and mutually recursive local functions.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , makeModule
        , makeModuleWithTypedDefs
        , pAnything
        , pInt
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Local tail-recursive functions "` followed by
`condStr`, that passes each program described above to `expectFn`.

The cases run under `Compiler.BulkCheck.bulkCheck`, so the test fails with the
label of the first case that fails, and the cases after it do not run.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Local tail-recursive functions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Builds the five labelled cases, each passing its program to `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Simple local tail-rec sumUpTo (LocalTailRecSimpleTest)", run = localTailRecSimple expectFn }
    , { label = "Outer tail-rec with local tail-rec def (TailRecWithLocalTailDefTest)", run = tailRecWithLocalTailDef expectFn }
    , { label = "Local tail-rec with captured outer variable", run = localTailRecPolyOuter expectFn }
    , { label = "Multiple local tail-rec defs in same let", run = multipleLocalTailRecs expectFn }
    , { label = "Nested local tail-rec (tail-rec inside tail-rec body)", run = nestedLocalTailRec expectFn }
    ]


{-| Builds and checks a module `Test` whose `testValue` is

    testValue =
        let
            sumUpTo i s =
                if i <= 0 then
                    s

                else
                    sumUpTo (i - 1) (s + i)
        in
        sumUpTo 10 0

Nothing is annotated, so `i` and `s` have the type `number`, not `Int`.

-}
localTailRecSimple : (Src.Module -> Expectation) -> (() -> Expectation)
localTailRecSimple expectFn _ =
    let
        sumUpToBody =
            ifExpr
                (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                (varExpr "s")
                (callExpr (varExpr "sumUpTo")
                    [ binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)
                    , binopsExpr [ ( varExpr "s", "+" ) ] (varExpr "i")
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr
                    [ define "sumUpTo" [ pVar "i", pVar "s" ] sumUpToBody ]
                    (callExpr (varExpr "sumUpTo") [ intExpr 10, intExpr 0 ])
                )
    in
    expectFn modul


{-| Builds and checks a module `Test` holding a local tail-recursive function
inside a top-level one that is also tail-recursive:

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
        outerLoop 10 0

-}
tailRecWithLocalTailDef : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecWithLocalTailDef expectFn _ =
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

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "outerLoop"
                  , args = [ pVar "n", pVar "acc" ]
                  , tipe = tLambda intType (tLambda intType intType)
                  , body = outerBody
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = intType
                  , body = callExpr (varExpr "outerLoop") [ intExpr 10, intExpr 0 ]
                  }
                ]
    in
    expectFn modul


{-| Builds and checks a module `Test` holding a local tail-recursive function
that captures an argument of the function it is defined in:

    process : Int -> Int
    process x =
        let
            loop i acc =
                if i <= 0 then
                    acc

                else
                    loop (i - 1) (acc + x)
        in
        loop x 0

    testValue : Int
    testValue =
        process 5

-}
localTailRecPolyOuter : (Src.Module -> Expectation) -> (() -> Expectation)
localTailRecPolyOuter expectFn _ =
    let
        intType =
            tType "Int" []

        loopBody =
            ifExpr
                (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                (varExpr "acc")
                (callExpr (varExpr "loop")
                    [ binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)
                    , binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "x")
                    ]
                )

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "process"
                  , args = [ pVar "x" ]
                  , tipe = tLambda intType intType
                  , body =
                        letExpr
                            [ define "loop" [ pVar "i", pVar "acc" ] loopBody ]
                            (callExpr (varExpr "loop") [ varExpr "x", intExpr 0 ])
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = intType
                  , body = callExpr (varExpr "process") [ intExpr 5 ]
                  }
                ]
    in
    expectFn modul


{-| Builds and checks a module `Test` whose `testValue` defines two local
tail-recursive functions in one `let` and adds their results:

    testValue =
        let
            countDown i =
                if i <= 0 then
                    0

                else
                    countDown (i - 1)

            sumUp i acc =
                if i <= 0 then
                    acc

                else
                    sumUp (i - 1) (acc + i)
        in
        countDown 5 + sumUp 5 0

Nothing is annotated.

-}
multipleLocalTailRecs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLocalTailRecs expectFn _ =
    let
        countDownBody =
            ifExpr
                (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                (intExpr 0)
                (callExpr (varExpr "countDown")
                    [ binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1) ]
                )

        sumUpBody =
            ifExpr
                (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                (varExpr "acc")
                (callExpr (varExpr "sumUp")
                    [ binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)
                    , binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "i")
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr
                    [ define "countDown" [ pVar "i" ] countDownBody
                    , define "sumUp" [ pVar "i", pVar "acc" ] sumUpBody
                    ]
                    (binopsExpr
                        [ ( callExpr (varExpr "countDown") [ intExpr 5 ], "+" ) ]
                        (callExpr (varExpr "sumUp") [ intExpr 5, intExpr 0 ])
                    )
                )
    in
    expectFn modul


{-| Builds and checks a module `Test` whose `testValue` defines a local
tail-recursive function `outer` with a local tail-recursive function `inner` in
its body:

    testValue =
        let
            outer n total =
                let
                    inner i acc =
                        if i <= 0 then
                            acc

                        else
                            inner (i - 1) (acc + 1)
                in
                if n <= 0 then
                    total

                else
                    outer (n - 1) (total + inner n 0)
        in
        outer 5 0

Both self-calls are in tail position, so both `outer` and `inner` are tail
definitions, one nested in the other. Nothing is annotated.

-}
nestedLocalTailRec : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLocalTailRec expectFn _ =
    let
        innerBody =
            ifExpr
                (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                (varExpr "acc")
                (callExpr (varExpr "inner")
                    [ binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)
                    , binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1)
                    ]
                )

        outerBody =
            letExpr
                [ define "inner" [ pVar "i", pVar "acc" ] innerBody ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (varExpr "total")
                    (callExpr (varExpr "outer")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        , binopsExpr [ ( varExpr "total", "+" ) ]
                            (callExpr (varExpr "inner") [ varExpr "n", intExpr 0 ])
                        ]
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr
                    [ define "outer" [ pVar "n", pVar "total" ] outerBody ]
                    (callExpr (varExpr "outer") [ intExpr 5, intExpr 0 ])
                )
    in
    expectFn modul
