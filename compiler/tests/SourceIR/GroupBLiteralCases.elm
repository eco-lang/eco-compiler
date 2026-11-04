module SourceIR.GroupBLiteralCases exposing (expectSuite)

{-| Programs that hold string, character and float literals and unit values in
different contexts, so that the placeholder each literal is typed through is
tied to a different kind of expected type: a top-level value, a list and a
tuple, a call argument and an `if` branch, and a `let` and a `case` branch.
PostSolve overwrites the type of each such literal with its form's type
(POST\_001).

They come from the former unit test `Compiler.Type.PostSolveGroupBTypesTest`,
whose check already ran over the catalogue as
`TestLogic.Type.PostSolve.PostSolveGroupBStructuralTypesTest`; that unit test
now only checks that each program here holds a literal.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, whose `testValue` uses its
other definitions. The cases, by label:

  - "literals at top level": `s = "hi"`, `c = 'x'`, `f = 1.5`, `u = ()` and
    `testValue = ( s, c, ( f, u ) )`.
  - "literals in containers": `pairs = [ ( "a", 'b' ), ( "c", 'd' ) ]`,
    `triple = ( 2.5, (), "e" )` and `testValue = ( pairs, triple )`.
  - "literals as call arguments and branches": `greet name = name`,
    `msg flag = if flag then greet "yes" else "no"` and
    `testValue = msg True`.
  - "literals in let and case":
    `g n = let z = 0.5 in case n of 0 -> ( z, "zero" ) _ -> ( 1.5, "other" )`
    and `testValue = g 0`.

Among what is not covered: shader literals, and annotated definitions.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Group B literal programs " followed by `condStr`,
that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Group B literal programs " ++ condStr) <|
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
    [ ( "literals at top level"
      , SB.makeModuleWithDefs "Test"
            [ ( "s", [], SB.strExpr "hi" )
            , ( "c", [], SB.chrExpr "x" )
            , ( "f", [], SB.floatExpr 1.5 )
            , ( "u", [], SB.unitExpr )
            , ( "testValue", [], SB.tuple3Expr (SB.varExpr "s") (SB.varExpr "c") (SB.tupleExpr (SB.varExpr "f") (SB.varExpr "u")) )
            ]
      )
    , ( "literals in containers"
      , SB.makeModuleWithDefs "Test"
            [ ( "pairs"
              , []
              , SB.listExpr
                    [ SB.tupleExpr (SB.strExpr "a") (SB.chrExpr "b")
                    , SB.tupleExpr (SB.strExpr "c") (SB.chrExpr "d")
                    ]
              )
            , ( "triple", [], SB.tuple3Expr (SB.floatExpr 2.5) SB.unitExpr (SB.strExpr "e") )
            , ( "testValue", [], SB.tupleExpr (SB.varExpr "pairs") (SB.varExpr "triple") )
            ]
      )
    , ( "literals as call arguments and branches"
      , SB.makeModuleWithDefs "Test"
            [ ( "greet", [ SB.pVar "name" ], SB.varExpr "name" )
            , ( "msg"
              , [ SB.pVar "flag" ]
              , SB.ifExpr (SB.varExpr "flag")
                    (SB.callExpr (SB.varExpr "greet") [ SB.strExpr "yes" ])
                    (SB.strExpr "no")
              )
            , ( "testValue", [], SB.callExpr (SB.varExpr "msg") [ SB.boolExpr True ] )
            ]
      )
    , ( "literals in let and case"
      , SB.makeModuleWithDefs "Test"
            [ ( "g"
              , [ SB.pVar "n" ]
              , SB.letExpr [ SB.define "z" [] (SB.floatExpr 0.5) ]
                    (SB.caseExpr (SB.varExpr "n")
                        [ ( SB.pInt 0, SB.tupleExpr (SB.varExpr "z") (SB.strExpr "zero") )
                        , ( SB.pAnything, SB.tupleExpr (SB.floatExpr 1.5) (SB.strExpr "other") )
                        ]
                    )
              )
            , ( "testValue", [], SB.callExpr (SB.varExpr "g") [ SB.intExpr 0 ] )
            ]
      )
    ]
