module TestLogic.Generate.CodeGen.CallTargetValidityTest exposing (suite)

{-| A call in generated MLIR that names a function the module does not define,
or that reaches an extern placeholder while a real definition sharing its base
name exists (both defined below), is a code generation error. These tests look for
both in the MLIR generated for each program of the standard catalogue.

The fixture is that catalogue: the programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` lists, each compiled with
`TestLogic.TestPipeline.runToMlir`.

An _extern placeholder_ and a _base name_ are as
`TestLogic.Generate.CodeGen.CallTargetValidity` defines them. In short, an
extern placeholder is the `func.func` generated for a `MonoExtern` node of the
monomorphized graph, and the base name of a symbol is the part before its last
`_$_`, or the whole symbol when it has none.

What the tests establish, for each program, through
`TestLogic.Generate.CodeGen.CallTargetValidity.expectCallTargetValidity`:

  - the program compiles to MLIR; if it does not, the test that runs it fails
    with the test pipeline's error message;
  - each `eco.call` with a `callee` attribute names a top-level `func.func` of
    the module;
  - no such call targets an extern placeholder while another top-level
    `func.func` with the same base name is a real definition.

Among what is not tested:

  - an `eco.call` with no `callee` attribute;
  - whether a call's operands or results fit the callee's signature;
  - references to functions from ops other than `eco.call`;
  - any program outside the catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CallTargetValidity exposing (expectCallTargetValidity)


{-| The tests that run the call target check on every program of the standard
catalogue, grouped under one `describe`.
-}
suite : Test
suite =
    Test.describe "CGEN_044: Call Target Validity"
        [ StandardTestSuites.expectSuite expectCallTargetValidity "passes call target validity invariant"
        ]
