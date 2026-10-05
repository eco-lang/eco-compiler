module TestLogic.Generate.CodeGen.CEcoValueLoweringTest exposing (suite)

{-| A type variable that monomorphization leaves with the `CEcoValue`
constraint stands for a value that is always boxed, and code generation is
expected to give it the MLIR type `!eco.value` (see `Constraint` in
`Compiler.AST.Monomorphized`). This suite runs the checker for that rule,
`TestLogic.Generate.CodeGen.CEcoValueLowering.expectCEcoValueLowering`, on
every program of the standard catalogue. It checks the signature of each
generated function against its monomorphized node: a `CEcoValue` parameter or
return type must be `!eco.value` in the `func.func` type.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites.expectSuite`
collects from the `SourceIR` case modules it includes. Most of its programs are
fixed; those of its fuzz tests vary from run to run.

What the tests establish:

  - `suite` applies the checker to each catalogue program: a program passes
    when it compiles to MLIR through `TestLogic.TestPipeline.runToMlir` and no
    generated function lowers a `CEcoValue` parameter or result to a type
    other than `!eco.value`.

Among what is not tested:

  - `CEcoValue` variables nested inside other types, SSA values inside
    function bodies, and nodes whose function is not generated under its
    `_$_<SpecId>` name; `CEcoValueLowering` lists the exact limits.

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
