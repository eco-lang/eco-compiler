module TestLogic.Generate.CodeGen.SingletonConstantsTest exposing (suite)

{-| Runs the singleton-constant check over the standard catalogue of test
programs, so that generated MLIR that builds a well-known value such as `True`,
`Nothing` or the empty string by construction rather than as an embedded
constant is caught on those programs.

The check is
`TestLogic.Generate.CodeGen.SingletonConstants.expectSingletonConstants`,
whose module docstring says what an embedded constant is and lists what it
reports. It compiles a program to MLIR and fails if compilation fails, or if
the MLIR holds an `eco.constant` whose `kind` is missing or not 0 (False),
1 (True) or 2 (the shared empty constant), an `eco.construct.custom` of size 0
(a nullary constructor built on the heap), or an `eco.string_literal` of the
empty string.

`suite` runs the check on the programs `SourceIR.Suite.StandardTestSuites`
gathers.

The catalogue includes, in `SourceIR.CaseCases`, a program declaring its own
`type Tri = True | False | Unknown` and matching it with a `case`, which the
check sees like any other. That those constructors dispatch exactly like
renamed ones, which guards
`Compiler.IR.Runtime.CtorTag.isEmbeddedConstantCtor`, is pinned by the unit
test `Compiler.IR.Runtime.CtorTagTest`.

Among what is not tested:

  - programs of the `SourceIR` case modules the standard catalogue leaves
    out, such as `SourceIR.CaseSafepointLeakCases`;
  - whether an `eco.constant` has the right kind for its value: any of the
    three kinds passes;
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
