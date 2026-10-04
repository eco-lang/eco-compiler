module TestLogic.Generate.DebugPolymorphismTest exposing (suite)

{-| A `Debug` kernel function such as `Debug.log` accepts a value of any type,
and once a program is monomorphized the types at its uses should hold no
`CNumber` type variable, one known only to be `Int` or `Float`.
`TestLogic.Generate.DebugPolymorphism.expectDebugPolymorphismResolved` checks
this on the monomorphized graph of a program, and these tests run it on four
small programs.

Each program is a module built with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, which imports only `Basics`
and `List` and annotates no definition. Each defines a top-level `testValue`,
the value the test pipeline builds the program around.
None of the four programs mentions `Debug`, so the check finds no `Debug` kernel
reference to inspect, and each test passes whenever
`TestLogic.TestPipeline.runToMono` returns a graph for its program.

The tests establish:

  - "monomorphic Int value": a program whose `testValue` is `x`, and `x` is the
    integer literal `42`, compiles to a monomorphized graph. With no annotation,
    nothing in the program fixes the literal's type to `Int`.
  - "monomorphic String value": the same with `x` the string literal `"hello"`.
  - "monomorphic function": a program defining `double x = x + x` and
    `testValue = double 5` compiles to a monomorphized graph. Neither is
    annotated, so nothing in the program fixes `double`'s type to `Int`.
  - "list of integers": a program whose `testValue` is `xs`, and `xs` is the
    list of integer literals `[ 1, 2, 3 ]`, compiles to a monomorphized graph.

Among what is not tested: any program that calls or refers to a `Debug`
function, so neither the types of `Debug` kernel references nor the argument
types of calls to them are ever examined here; and the values the `Debug`
functions print or return, since nothing is run.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Generate.DebugPolymorphism exposing (expectDebugPolymorphismResolved)


{-| The tests of this module, the four in `debugTests`.
-}
suite : Test
suite =
    Test.describe "Debug kernel functions handle polymorphism (MONO_009)"
        [ debugTests
        ]


{-| The four tests the module docstring lists, each passing one built module to
`expectDebugPolymorphismResolved`.
-}
debugTests : Test
debugTests =
    Test.describe "Debug polymorphism resolution"
        [ Test.test "monomorphic Int value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoInt"
                            [ ( "x", [], SB.intExpr 42 )
                            , ( "testValue", [], SB.varExpr "x" )
                            ]
                in
                expectDebugPolymorphismResolved modul
        , Test.test "monomorphic String value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoStr"
                            [ ( "x", [], SB.strExpr "hello" )
                            , ( "testValue", [], SB.varExpr "x" )
                            ]
                in
                expectDebugPolymorphismResolved modul
        , Test.test "monomorphic function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoFunc"
                            [ ( "double"
                              , [ SB.pVar "x" ]
                              , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "x")
                              )
                            , ( "testValue", [], SB.callExpr (SB.varExpr "double") [ SB.intExpr 5 ] )
                            ]
                in
                expectDebugPolymorphismResolved modul
        , Test.test "list of integers" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "IntList"
                            [ ( "xs", [], SB.listExpr [ SB.intExpr 1, SB.intExpr 2, SB.intExpr 3 ] )
                            , ( "testValue", [], SB.varExpr "xs" )
                            ]
                in
                expectDebugPolymorphismResolved modul
        ]
