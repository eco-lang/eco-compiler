module TestLogic.Generate.CodeGen.CallAbiConsistencyTest exposing (suite)

{-| A call that passes an operand of a type its callee does not declare hands
the callee a value in a representation it does not expect, such as a Bool as
`i1` where the parameter is `!eco.value`. `Mlir.Mlir` does not tie a call's
operand types to its callee's signature, so such a call is built without
complaint. These tests look for one in the MLIR generated for each program of
the standard catalogue.

The fixture is that catalogue: the programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` lists, each compiled with
`TestLogic.TestPipeline.runToMlir`.

What the tests establish, for each program, through
`TestLogic.Generate.CodeGen.CallAbiConsistency.expectCallAbiConsistency`:

  - the program compiles to MLIR; if it does not, the test that runs it fails
    with the test pipeline's error message;
  - each `eco.call` whose callee is a top-level `func.func` with a
    `function_type` has, once its trailing GC-root hint operands (operands
    appended after the arguments for the garbage collector, as many as its
    `eco.gc_roots_count` attribute says) are dropped, one operand for each of
    the callee's parameters, and each operand type equals the parameter type at
    the same position.

Among what is not tested:

  - an `eco.call` whose callee has no top-level `func.func` with a
    `function_type`, or that has no `callee` or no `_operand_types` attribute;
  - the result types of a call;
  - any program outside the catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CallAbiConsistency exposing (expectCallAbiConsistency)


{-| The tests that run the call operand type check on every program of the
standard catalogue, grouped under one `describe`.
-}
suite : Test
suite =
    Test.describe "REP_ABI_001: Call ABI Consistency"
        [ StandardTestSuites.expectSuite expectCallAbiConsistency "passes call ABI consistency invariant"
        ]
