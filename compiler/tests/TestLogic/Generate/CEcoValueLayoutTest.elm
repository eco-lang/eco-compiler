module TestLogic.Generate.CEcoValueLayoutTest exposing (suite)

{-| Runs the `CEcoValue` layout check over the standard catalogue of test
programs. As that check stands, this amounts to requiring every program it is
given to monomorphize.

A `CEcoValue` type variable is one that monomorphization leaves open and that
the back end holds as a boxed value, as `Compiler.AST.Monomorphized` describes.
The check, `TestLogic.Generate.CEcoValueLayout.expectValidCEcoValueLayout`, is
named for the property that such a variable never decides how a record, tuple
or constructor is laid out, or how a function is called. Its walk of the
monomorphized graph finds no issue in any graph, so it passes exactly when the
test pipeline's run to monomorphization (`TestLogic.TestPipeline.runToMono`)
succeeds.

The fixture is the set of programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` includes.

What `suite` establishes:

  - that each program those case modules hand to the check runs through the
    test pipeline as far as monomorphization without an error.

Among what is not tested: where a `CEcoValue` variable appears in any type, and
the layout of records, tuples and constructors.

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
