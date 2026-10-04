module TestLogic.Generate.CodeGen.TypeTableUniquenessTest exposing (suite)

{-| These tests exist so that a generated MLIR module holding more than one type
table is caught on every program in the standard `SourceIR` catalogue, not only
on a few chosen by hand. A type table is an `eco.type_table` op, which the code
generator emits as a top-level op of the module to record the program's types.

The fixture is that catalogue, the programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers.

`suite` gives each program to
`TestLogic.Generate.CodeGen.TypeTableUniqueness.expectTypeTableUniqueness`. The
test for a program passes when the program compiles to MLIR through
`TestLogic.TestPipeline.runToMlir`, and the module's top-level ops include at
most one `eco.type_table`. A module with none passes.

Among what is not tested: type tables nested inside other ops' regions; that a
type table is present at all, or what it contains; and the MLIR the build
emits, which `runToMlir` does not produce with the build's own writers.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.TypeTableUniqueness exposing (expectTypeTableUniqueness)


{-| The standard catalogue run through `expectTypeTableUniqueness`, as one group
of tests.
-}
suite : Test
suite =
    Test.describe "CGEN_035: Type Table Uniqueness"
        [ StandardTestSuites.expectSuite expectTypeTableUniqueness "passes type table uniqueness invariant"
        ]
