module SourceIR.TailDefTypeCases exposing (expectSuite)

{-| Two annotated, self-recursive top-level functions with plain-variable
parameters that call themselves in tail position, so that the typed optimizer
turns each into a `TailDef` inside a `Cycle` node: one recursing from an `if`
and one from a `case` on its list parameter. They come from the former inline
programs of `Compiler.LocalOpt.Typed.TailDefTypesTest`, whose check, that a
`TailDef`'s parameters and body have the types its annotation declares
(TOPT\_004, TOPT\_005), is now a rule of `TestLogic.LocalOpt.TypePreservation`
and runs over the whole catalogue; that unit test now only pins that each
program here has a `TailDef`.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefs`, with a `testValue` that
calls its function. The cases, by label:

  - "sumHelper": `sumHelper : Int -> Int -> Int`, recursing from the `else`
    branch of an `if`.
  - "sumList": `sumList : List Int -> Int -> Int`, recursing from the `::`
    branch of a `case` on its list.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pCons
        , pList
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Annotated TailDef programs " followed by `condStr`,
that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Annotated TailDef programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul })
        [ ( "sumHelper", sumHelperModule )
        , ( "sumList", sumListModule )
        ]


{-| A module with an annotated, tail-recursive `sumHelper` and a `testValue`
that calls it. As Elm source:

    sumHelper : Int -> Int -> Int
    sumHelper acc n =
        if n <= 0 then
            acc

        else
            sumHelper (acc + n) (n - 1)

    testValue : Int
    testValue =
        sumHelper 0 10

-}
sumHelperModule : Src.Module
sumHelperModule =
    let
        intType =
            tType "Int" []

        funcType =
            tLambda intType (tLambda intType intType)
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "sumHelper"
          , args = [ pVar "acc", pVar "n" ]
          , tipe = funcType
          , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (callExpr (varExpr "sumHelper")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "n")
                        , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        ]
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body = callExpr (varExpr "sumHelper") [ intExpr 0, intExpr 10 ]
          }
        ]


{-| A module with an annotated, tail-recursive `sumList` that matches on its
list, and a `testValue` that calls it. As Elm source:

    sumList : List Int -> Int -> Int
    sumList xs acc =
        case xs of
            [] ->
                acc

            x :: rest ->
                sumList rest (acc + x)

    testValue : Int
    testValue =
        sumList [ 1, 2, 3 ] 0

-}
sumListModule : Src.Module
sumListModule =
    let
        intType =
            tType "Int" []
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "sumList"
          , args = [ pVar "xs", pVar "acc" ]
          , tipe = tLambda (tType "List" [ intType ]) (tLambda intType intType)
          , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "x") (pVar "rest")
                      , callExpr (varExpr "sumList")
                            [ varExpr "rest"
                            , binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "x")
                            ]
                      )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body = callExpr (varExpr "sumList") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ], intExpr 0 ]
          }
        ]
