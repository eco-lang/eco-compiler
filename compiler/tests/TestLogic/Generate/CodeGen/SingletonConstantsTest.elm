module TestLogic.Generate.CodeGen.SingletonConstantsTest exposing (suite)

{-| Runs the singleton-constant check over the standard catalogue of test
programs, so that generated MLIR that builds a well-known value such as `True`,
`Nothing` or the empty string by construction rather than as an embedded
constant is caught on those programs.

The check is
`TestLogic.Generate.CodeGen.SingletonConstants.expectSingletonConstants`,
whose module docstring says what an embedded constant is and lists what it
reports. It compiles a program to MLIR and fails if compilation fails, or if
the MLIR holds an `eco.constant` whose `kind` is missing or outside 1 to 7, an
`eco.construct.custom` whose `constructor` is `True`, `False`, `Nothing`,
`Nil` or `Unit`, or an `eco.string_literal` of the empty string.

`suite` runs the check on the programs `SourceIR.Suite.StandardTestSuites`
gathers.

Among what is not tested:

  - programs of the `SourceIR` case modules the standard catalogue leaves
    out, such as `SourceIR.CaseSafepointLeakCases`;
  - whether an `eco.constant` has the right kind for its value: any kind from
    1 to 7 passes;
  - a well-known value built by an op the check does not examine, as its
    module docstring lists.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SingletonConstants exposing (expectSingletonConstants)


{-| The singleton-constant check applied to the programs of the standard
catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_019: Singleton Constants"
        [ StandardTestSuites.expectSuite expectSingletonConstants "passes singleton constants invariant"
        ]
