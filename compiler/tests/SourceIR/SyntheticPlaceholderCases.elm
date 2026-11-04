module SourceIR.SyntheticPlaceholderCases exposing (expectSuite)

{-| Small programs in which some expressions are typed through a _synthetic
placeholder_, a fresh type variable that constraint generation ties to the
type the expression's context expects, in contexts where that tie is easy to
drop: a `let` that is the body of another, and the conditions of a chain of
`if`s. A placeholder no constraint reached would survive PostSolve in the node
types (POST\_003).

They come from the former unit test `Compiler.Type.PostSolveNoSyntheticVarsTest`.
Its check, an orphan placeholder variable left in its own node's type after
PostSolve, is covered by `TestLogic.Type.PostSolve.PostSolveNoSyntheticHolesTest`,
which fails on such a variable in any node's type and already ran over the
catalogue, so only the programs moved. That test's program `id x = x` is the
"polymorphic function" case of `SourceIR.CachedTypeInfoCases`.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, whose `testValue` uses its
definition. The cases, by label:

  - "fully constrained expression": `x = 1 + 2`, `testValue = x`.
  - "nested let": `f = let x = 1 in let y = x in y`, `testValue = f`.
  - "if chain conditions": `pick d = if True then 1 else (if d then 2 else 3)`,
    `testValue = pick False`. `True` and the reference to `d` are placeholder
    nodes typed only by being conditions; the outer condition's constraint
    was once dropped under the JavaScript backend, leaving the placeholder of
    `True` unconstrained.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Synthetic placeholder programs " followed by
`condStr`, that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Synthetic placeholder programs " ++ condStr) <|
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
    [ ( "fully constrained expression"
      , SB.makeModuleWithDefs "Test"
            [ ( "x", [], SB.binopsExpr [ ( SB.intExpr 1, "+" ) ] (SB.intExpr 2) )
            , ( "testValue", [], SB.varExpr "x" )
            ]
      )
    , ( "nested let"
      , SB.makeModuleWithDefs "Test"
            [ ( "f"
              , []
              , SB.letExpr
                    [ SB.define "x" [] (SB.intExpr 1) ]
                    (SB.letExpr
                        [ SB.define "y" [] (SB.varExpr "x") ]
                        (SB.varExpr "y")
                    )
              )
            , ( "testValue", [], SB.varExpr "f" )
            ]
      )
    , ( "if chain conditions"
      , SB.makeModuleWithDefs "Test"
            [ ( "pick"
              , [ SB.pVar "d" ]
              , SB.ifExpr (SB.boolExpr True)
                    (SB.intExpr 1)
                    (SB.parensExpr (SB.ifExpr (SB.varExpr "d") (SB.intExpr 2) (SB.intExpr 3)))
              )
            , ( "testValue", [], SB.callExpr (SB.varExpr "pick") [ SB.boolExpr False ] )
            ]
      )
    ]
