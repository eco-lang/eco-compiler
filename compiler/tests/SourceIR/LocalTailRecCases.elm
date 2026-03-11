module SourceIR.LocalTailRecCases exposing (expectSuite)

{-| Test cases for local tail-recursive functions (MonoTailDef in let bindings).

These cases exercise monomorphization of tail-recursive functions defined in
let bindings, which must be fully specialized just like top-level functions.
They target the bug exposed by MONO\_021 where local tail-recursive functions
retain CEcoValue MVar in their parameter types instead of being specialized
to concrete types like MInt.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Local tail-recursive functions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Simple local tail-rec sumUpTo (LocalTailRecSimpleTest)", run = localTailRecSimple expectFn }
    , { label = "Outer tail-rec with local tail-rec def (TailRecWithLocalTailDefTest)", run = tailRecWithLocalTailDef expectFn }
    , { label = "Local tail-rec with captured outer variable", run = localTailRecPolyOuter expectFn }
    , { label = "Multiple local tail-rec defs in same let", run = multipleLocalTailRecs expectFn }
    , { label = "Nested local tail-rec (tail-rec inside tail-rec body)", run = nestedLocalTailRec expectFn }
    ]


{-| Mirror of test/elm/src/LocalTailRecSimpleTest.elm:

    let
        sumUpTo i s =
            if i <= 0 then s else sumUpTo (i - 1) (s + i)
    in
    sumUpTo 10 0

This creates a MonoTailDef in a let binding. The parameters i and s must be
specialized to MInt, not left as MVar \_ CEcoValue.

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


{-| Mirror of test/elm/src/TailRecWithLocalTailDefTest.elm:

    outerLoop : Int -> Int -> Int
    outerLoop n acc =
        let
            sumUpTo i s =
                if i <= 0 then s else sumUpTo (i - 1) (s + i)

            localResult = sumUpTo n 0
        in
        case localResult of
            0 -> acc
            \_ -> outerLoop (n - 1) (acc + localResult)

This creates a MonoTailDef inside the body of another tail-recursive function.
Both the outer MonoTailFunc and the inner MonoTailDef must have fully specialized
parameter types.

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


{-| Local tail-rec function that captures an outer variable, ensuring the
specialization propagates through the capture context.

    process : Int -> Int
    process x =
        let
            loop i acc =
                if i <= 0 then acc else loop (i - 1) (acc + x)
        in
        loop x 0

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


{-| Two local tail-rec functions in the same let block.

    let
        countDown i = if i <= 0 then 0 else countDown (i - 1)
        sumUp i acc = if i <= 0 then acc else sumUp (i - 1) (acc + i)
    in
    countDown 5 + sumUp 5 0

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


{-| Nested tail-rec: a tail-rec function whose body contains another let with
a tail-rec definition.

    let
        outer n =
            let
                inner i acc =
                    if i <= 0 then acc else inner (i - 1) (acc + 1)
            in
            if n <= 0 then 0 else inner n 0 + outer (n - 1)
    in
    outer 5

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
                    (intExpr 0)
                    (binopsExpr
                        [ ( callExpr (varExpr "inner") [ varExpr "n", intExpr 0 ], "+" ) ]
                        (callExpr (varExpr "outer") [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ])
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr
                    [ define "outer" [ pVar "n" ] outerBody ]
                    (callExpr (varExpr "outer") [ intExpr 5 ])
                )
    in
    expectFn modul
