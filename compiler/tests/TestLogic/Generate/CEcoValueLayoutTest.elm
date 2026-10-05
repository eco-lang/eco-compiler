module TestLogic.Generate.CEcoValueLayoutTest exposing (suite)

{-| Runs the open-type-variable layout check over the standard catalogue of
test programs.

A `CEcoValue` type variable is one that monomorphization leaves open and that
the back end holds as a boxed value, so it never decides a layout (MONO\_003).
A `CNumber` variable would decide one (an unboxed `Int` or `Float`), so none
may survive monomorphization (MONO\_002, MONO\_028). The check,
`TestLogic.Generate.CEcoValueLayout.expectValidCEcoValueLayout`, runs each
program through `TestLogic.TestPipeline.runToMono` and fails on any
`MVar _ CNumber` in a node type, parameter type, constructor field type,
constructor shape, or expression type of the graph; its docstring lists the
positions.

The fixture is the set of programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` includes.

Among what is not tested: where a `CEcoValue` variable appears, which MONO\_003
allows anywhere, and the layout code generation then chooses.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CEcoValueLayout exposing (expectValidCEcoValueLayout)


{-| The test group that applies `expectValidCEcoValueLayout` to the standard
catalogue of test programs.
-}
suite : Test
suite =
    Test.describe "CEcoValue layout is consistent (MONO_003)"
        [ StandardTestSuites.expectSuite expectValidCEcoValueLayout "has valid CEcoValue layout"
        ]
