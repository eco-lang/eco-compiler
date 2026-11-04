module SourceIR.BorrowTailCallCases exposing (expectSuite)

{-| A tail-recursive function whose accumulator is a heap value, a `List Int`,
passed in a tail call, beside a let-bound list that is live only up to a
`case`, so that borrow inference has a tail-call argument resource that must
stay live to the end of the body and a resource that dies before it. It comes
from the former inline program of
`Compiler.MonoOpt.Borrow.BorrowTailCallEscapeTest`, whose check now runs over
the whole catalogue as `TestLogic.MonoOpt.BorrowTailCallEscapeTest`; that unit
test keeps the negative control, that some resource of this program is dead
at the end of the body.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

The program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefs`. The case, by label:

  - "List accumulator in a tail call":

        loop : Int -> List Int -> List Int
        loop n acc =
            if n <= 0 then
                acc

            else
                let
                    xs =
                        [ n, n ]
                in
                case xs of
                    x :: _ ->
                        loop (n - 1) (x :: acc)

                    _ ->
                        acc

        testValue : List Int
        testValue =
            loop 10 []

    The self-call in the `case` branch is the tail call; of its two
    arguments, only `x :: acc` has a resource.

-}

import Compiler.AST.SourceBuilder as B
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Borrow tail-call programs " followed by `condStr`,
that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Borrow tail-call programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul })
        [ ( "List accumulator in a tail call", listAccumulator ) ]


{-| The program of "List accumulator in a tail call", as the module docstring
shows it.
-}
listAccumulator : Src.Module
listAccumulator =
    let
        intType =
            B.tType "Int" []

        listIntType =
            B.tType "List" [ intType ]

        loopBody =
            B.ifExpr
                (B.binopsExpr [ ( B.varExpr "n", "<=" ) ] (B.intExpr 0))
                (B.varExpr "acc")
                (B.letExpr [ B.define "xs" [] (B.listExpr [ B.varExpr "n", B.varExpr "n" ]) ]
                    (B.caseExpr (B.varExpr "xs")
                        [ ( B.pCons (B.pVar "x") B.pAnything
                          , B.callExpr (B.varExpr "loop")
                                [ B.binopsExpr [ ( B.varExpr "n", "-" ) ] (B.intExpr 1)
                                , B.binopsExpr [ ( B.varExpr "x", "::" ) ] (B.varExpr "acc")
                                ]
                          )
                        , ( B.pAnything, B.varExpr "acc" )
                        ]
                    )
                )
    in
    B.makeModuleWithTypedDefs "Test"
        [ { name = "loop"
          , args = [ B.pVar "n", B.pVar "acc" ]
          , tipe = B.tLambda intType (B.tLambda listIntType listIntType)
          , body = loopBody
          }
        , { name = "testValue"
          , args = []
          , tipe = listIntType
          , body = B.callExpr (B.varExpr "loop") [ B.intExpr 10, B.listExpr [] ]
          }
        ]
