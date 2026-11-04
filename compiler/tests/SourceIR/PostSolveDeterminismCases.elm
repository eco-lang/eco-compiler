module SourceIR.PostSolveDeterminismCases exposing (expectSuite)

{-| Two small unannotated functions, one an `if` over a comparison and one an
operator chain nested inside another, from the former unit test
`Compiler.Type.PostSolveDeterminismTest` (POST\_004), whose check now runs over
the whole catalogue as `TestLogic.Type.PostSolve.PostSolveDeterminismTest`.
That test's third program, `x = 42`, is the "simple typed value" case of
`SourceIR.CachedTypeInfoCases`.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, with a `testValue` that calls
its function. The cases, by label:

  - "if over a comparison": `max x y = if x > y then x else y`,
    `testValue = max 3 4`.
  - "nested operator chain": `addThree a b c = (a + b) + c`, where the inner
    sum is an operator chain nested inside the outer one rather than a
    parenthesised expression, `testValue = addThree 1 2 3`.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Determinism programs " followed by `condStr`, that
passes `expectFn` each program in order through `Compiler.BulkCheck.bulkCheck`,
so the first failing program ends the test and is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Determinism programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul }) programs


{-| The programs, by label.
-}
programs : List ( String, Src.Module )
programs =
    [ ( "if over a comparison"
      , SB.makeModuleWithDefs "Test"
            [ ( "max"
              , [ SB.pVar "x", SB.pVar "y" ]
              , SB.ifExpr
                    (SB.binopsExpr [ ( SB.varExpr "x", ">" ) ] (SB.varExpr "y"))
                    (SB.varExpr "x")
                    (SB.varExpr "y")
              )
            , ( "testValue", [], SB.callExpr (SB.varExpr "max") [ SB.intExpr 3, SB.intExpr 4 ] )
            ]
      )
    , ( "nested operator chain"
      , SB.makeModuleWithDefs "Test"
            [ ( "addThree"
              , [ SB.pVar "a", SB.pVar "b", SB.pVar "c" ]
              , SB.binopsExpr
                    [ ( SB.binopsExpr [ ( SB.varExpr "a", "+" ) ] (SB.varExpr "b"), "+" ) ]
                    (SB.varExpr "c")
              )
            , ( "testValue", [], SB.callExpr (SB.varExpr "addThree") [ SB.intExpr 1, SB.intExpr 2, SB.intExpr 3 ] )
            ]
      )
    ]
