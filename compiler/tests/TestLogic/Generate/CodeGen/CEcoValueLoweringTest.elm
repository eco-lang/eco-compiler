module TestLogic.Generate.CodeGen.CEcoValueLoweringTest exposing (suite)

{-| A type variable that monomorphization leaves with the `CEcoValue`
constraint stands for a value that is always boxed, and code generation is
expected to give it the MLIR type `!eco.value` (see `Constraint` in
`Compiler.AST.Monomorphized`). This suite runs the checker named for that rule,
`TestLogic.Generate.CodeGen.CEcoValueLowering.expectCEcoValueLowering`, on
every program of the standard catalogue. As that module describes, the checker
reports no violations, so in effect this suite checks only that each program
compiles to MLIR.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites.expectSuite`
collects from the `SourceIR` case modules it includes. Most of its programs are
fixed; those of its fuzz tests vary from run to run.

What the tests establish:

  - `suite` applies the checker to each catalogue program: a program passes
    when it compiles to MLIR through `TestLogic.TestPipeline.runToMlir`, and
    fails otherwise.

Among what is not tested:

  - the rule itself: no MLIR type in the result can fail a test.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CEcoValueLowering exposing (expectCEcoValueLowering)


{-| The `CEcoValue` lowering checker applied to every program of the standard
catalogue, grouped under `CGEN_013: CEcoValue Lowering`.
-}
suite : Test
suite =
    Test.describe "CGEN_013: CEcoValue Lowering"
        [ StandardTestSuites.expectSuite expectCEcoValueLowering "passes CEcoValue lowering invariant"
        ]
