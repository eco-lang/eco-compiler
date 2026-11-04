module SourceIR.LetPolyNameCases exposing (expectSuite)

{-| Programs whose top-level function takes an argument and defines a
let-bound polymorphic helper whose type variable is not the argument's, so
that a type checker naming two different solver variables alike within one
definition would give the helper the argument's variable name. They come from
the former unit test `Compiler.Type.NodeTypeVarNamesDistinctTest`, whose check
now runs over the whole catalogue as
`TestLogic.Type.NodeTypeVarNamesDistinctTest`.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, with a `testValue` that calls
its functions. The cases, by label:

  - "let helper beside the enclosing argument":
    `f x = let h y = y in ( h x, h 1 )` and `testValue = f "s"`.
  - "let helper next to another polymorphic definition": `first p q = p` and
    `g z = let k w = w in ( k z, k "s" )`, with
    `testValue = ( first 1 'c', g 2.5 )`; a name shared between `first` and
    `g` is allowed, since each definition is checked on its own.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Let-polymorphic helper programs " followed by
`condStr`, that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let-polymorphic helper programs " ++ condStr) <|
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
    [ ( "let helper beside the enclosing argument"
      , SB.makeModuleWithDefs "Test"
            [ ( "f"
              , [ SB.pVar "x" ]
              , SB.letExpr [ SB.define "h" [ SB.pVar "y" ] (SB.varExpr "y") ]
                    (SB.tupleExpr
                        (SB.callExpr (SB.varExpr "h") [ SB.varExpr "x" ])
                        (SB.callExpr (SB.varExpr "h") [ SB.intExpr 1 ])
                    )
              )
            , ( "testValue", [], SB.callExpr (SB.varExpr "f") [ SB.strExpr "s" ] )
            ]
      )
    , ( "let helper next to another polymorphic definition"
      , SB.makeModuleWithDefs "Test"
            [ ( "first", [ SB.pVar "p", SB.pVar "q" ], SB.varExpr "p" )
            , ( "g"
              , [ SB.pVar "z" ]
              , SB.letExpr [ SB.define "k" [ SB.pVar "w" ] (SB.varExpr "w") ]
                    (SB.tupleExpr (SB.callExpr (SB.varExpr "k") [ SB.varExpr "z" ]) (SB.callExpr (SB.varExpr "k") [ SB.strExpr "s" ]))
              )
            , ( "testValue"
              , []
              , SB.tupleExpr
                    (SB.callExpr (SB.varExpr "first") [ SB.intExpr 1, SB.chrExpr "c" ])
                    (SB.callExpr (SB.varExpr "g") [ SB.floatExpr 2.5 ])
              )
            ]
      )
    ]
