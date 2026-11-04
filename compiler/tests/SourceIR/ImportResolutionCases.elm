module SourceIR.ImportResolutionCases exposing (expectSuite)

{-| Small programs that take names from their imports in the basic ways: a
qualified and an unqualified imported function, operators of `Basics` and
`List`, and a constructor of `Basics`, beside one that refers only to its own
definitions. They come from the former unit test
`Compiler.Canonicalize.ImportResolutionTest` (CANON\_004), whose check now
runs over the whole catalogue as `TestLogic.Canonicalize.ImportResolutionTest`.
That test's program `x = 42` is the "simple typed value" case of
`SourceIR.CachedTypeInfoCases`.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, so it imports `Basics` and
`List`, each exposing everything, and its definitions are unannotated; each
has a `testValue` that uses them. The cases, by label:

  - "local function calls": `f x = x`, `g y = f y`, `testValue = g 1`.
  - "qualified imported function": `xs = List.map negate [ 1, 2 ]`,
    `testValue = xs`.
  - "imported operators": `n = 1 + 2 * 3`, `ys = 1 :: []`,
    `testValue = ( n, ys )`.
  - "imported constructor": `t = True`, `testValue = t`.

Among what is not covered: an import with an alias or an explicit `exposing`
list.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Import resolution programs " followed by `condStr`,
that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Import resolution programs " ++ condStr) <|
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
    [ ( "local function calls"
      , SB.makeModuleWithDefs "Test"
            [ ( "f", [ SB.pVar "x" ], SB.varExpr "x" )
            , ( "g", [ SB.pVar "y" ], SB.callExpr (SB.varExpr "f") [ SB.varExpr "y" ] )
            , ( "testValue", [], SB.callExpr (SB.varExpr "g") [ SB.intExpr 1 ] )
            ]
      )
    , ( "qualified imported function"
      , SB.makeModuleWithDefs "Test"
            [ ( "xs"
              , []
              , SB.callExpr (SB.qualVarExpr "List" "map")
                    [ SB.varExpr "negate", SB.listExpr [ SB.intExpr 1, SB.intExpr 2 ] ]
              )
            , ( "testValue", [], SB.varExpr "xs" )
            ]
      )
    , ( "imported operators"
      , SB.makeModuleWithDefs "Test"
            [ ( "n", [], SB.binopsExpr [ ( SB.intExpr 1, "+" ), ( SB.intExpr 2, "*" ) ] (SB.intExpr 3) )
            , ( "ys", [], SB.binopsExpr [ ( SB.intExpr 1, "::" ) ] (SB.listExpr []) )
            , ( "testValue", [], SB.tupleExpr (SB.varExpr "n") (SB.varExpr "ys") )
            ]
      )
    , ( "imported constructor"
      , SB.makeModuleWithDefs "Test"
            [ ( "t", [], SB.ctorExpr "True" )
            , ( "testValue", [], SB.varExpr "t" )
            ]
      )
    ]
