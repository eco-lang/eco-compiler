module TestLogic.Generate.CodeGen.PapCreateArityTest exposing (suite)

{-| These tests run the `eco.papCreate` attribute check on the standard
catalogue of test programs, so that the code generator building a closure whose
attributes do not describe a partial application is caught on any of those
programs, not only on a hand-picked few.

An `eco.papCreate` builds a partial application object (PAP): a closure over a
function that holds some of the function's arguments and waits for the rest.
Its `arity` attribute counts all the arguments, and `num_captured` the ones
already held, which are the op's operands.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites.expectSuite`
collects from the `SourceIR` case modules. The check is
`TestLogic.Generate.CodeGen.PapCreateArity.expectPapCreateArity`.

What the tests establish:

  - `suite`: for each catalogue program, the program compiles to MLIR with
    `runToMlir`, and each `eco.papCreate` in the result has an integer `arity`
    greater than zero, an integer `num_captured` equal to its operand count and
    less than `arity`, and a `function` attribute that is a string or a symbol
    reference. A failing test reports only the first violation found.

Among what is not tested: closures built by `eco.papCreateGroup`, whether
`function` names a function that exists, and whether `arity` agrees with that
function.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapCreateArity exposing (expectPapCreateArity)


{-| The test group that applies the `eco.papCreate` attribute check to each
program in the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_033: PapCreate Arity Constraints"
        [ StandardTestSuites.expectSuite expectPapCreateArity "passes papCreate arity invariant"
        ]
