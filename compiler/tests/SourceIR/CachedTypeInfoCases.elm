module SourceIR.CachedTypeInfoCases exposing (expectSuite)

{-| Small programs whose top-level definitions are a value, a polymorphic
function and a higher-order function, unannotated and annotated, so that a
check on the types that type checking records for a module's top-level names
sees both an inferred and a written type. They come from the former unit test
`Compiler.Type.CachedTypeInfoTest` (CANON\_006), whose check now runs over the
whole catalogue as `TestLogic.Type.CachedTypeInfoTest`.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program is one module named `Test` that ends with a value `testValue`
applying its functions, so that the stages after typed optimization, which
build the program around `testValue`, reach them. The first three are built
with `Compiler.AST.SourceBuilder.makeModuleWithDefs` and carry no annotation;
the last two with `makeModuleWithTypedDefs`, where every definition is
annotated. The cases, by label:

  - "simple typed value": `x = 42`, `testValue = x`.
  - "polymorphic function": `id x = x`, `testValue = id 1`.
  - "higher-order function": `apply f x = f x`,
    `testValue = apply (\n -> n + 1) 3`.
  - "annotated polymorphic functions": `id : a -> a`,
    `pair : a -> b -> ( a, b )` and `testValue : ( Int, String )`,
    `testValue = pair (id 1) "s"`.
  - "annotated extensible record": `getX : { r | x : Int } -> Int` and
    `testValue : Int`, `testValue = getX { x = 1, y = 2 }`.

Among what is not covered: custom types, aliases, and definitions inside a
`let`.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Cached type info programs " followed by `condStr`,
that passes `expectFn` each program in the order listed above through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Cached type info programs " ++ condStr) <|
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
    [ ( "simple typed value"
      , SB.makeModuleWithDefs "Test"
            [ ( "x", [], SB.intExpr 42 )
            , ( "testValue", [], SB.varExpr "x" )
            ]
      )
    , ( "polymorphic function"
      , SB.makeModuleWithDefs "Test"
            [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" )
            , ( "testValue", [], SB.callExpr (SB.varExpr "id") [ SB.intExpr 1 ] )
            ]
      )
    , ( "higher-order function"
      , SB.makeModuleWithDefs "Test"
            [ ( "apply"
              , [ SB.pVar "f", SB.pVar "x" ]
              , SB.callExpr (SB.varExpr "f") [ SB.varExpr "x" ]
              )
            , ( "testValue"
              , []
              , SB.callExpr (SB.varExpr "apply")
                    [ SB.lambdaExpr [ SB.pVar "n" ] (SB.binopsExpr [ ( SB.varExpr "n", "+" ) ] (SB.intExpr 1))
                    , SB.intExpr 3
                    ]
              )
            ]
      )
    , ( "annotated polymorphic functions"
      , SB.makeModuleWithTypedDefs "Test"
            [ { name = "id"
              , args = [ SB.pVar "x" ]
              , tipe = SB.tLambda (SB.tVar "a") (SB.tVar "a")
              , body = SB.varExpr "x"
              }
            , { name = "pair"
              , args = [ SB.pVar "x", SB.pVar "y" ]
              , tipe =
                    SB.tLambda (SB.tVar "a")
                        (SB.tLambda (SB.tVar "b") (SB.tTuple (SB.tVar "a") (SB.tVar "b")))
              , body = SB.tupleExpr (SB.varExpr "x") (SB.varExpr "y")
              }
            , { name = "testValue"
              , args = []
              , tipe = SB.tTuple (SB.tType "Int" []) (SB.tType "String" [])
              , body =
                    SB.callExpr (SB.varExpr "pair")
                        [ SB.callExpr (SB.varExpr "id") [ SB.intExpr 1 ], SB.strExpr "s" ]
              }
            ]
      )
    , ( "annotated extensible record"
      , SB.makeModuleWithTypedDefs "Test"
            [ { name = "getX"
              , args = [ SB.pVar "r" ]
              , tipe = SB.tLambda (SB.tExtRecord "r" [ ( "x", SB.tType "Int" [] ) ]) (SB.tType "Int" [])
              , body = SB.accessExpr (SB.varExpr "r") "x"
              }
            , { name = "testValue"
              , args = []
              , tipe = SB.tType "Int" []
              , body =
                    SB.callExpr (SB.varExpr "getX")
                        [ SB.recordExpr [ ( "x", SB.intExpr 1 ), ( "y", SB.intExpr 2 ) ] ]
              }
            ]
      )
    ]
