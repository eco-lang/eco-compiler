module TestLogic.Generate.CodeGen.EcoUnboxSanityTest exposing (suite)

{-| Runs the `eco.unbox` type check on every program in the standard catalogue,
so that MLIR generation which unboxes something other than a boxed value, or
into something other than a primitive, does not go unnoticed on any of those
programs.

`eco.unbox` is the MLIR op that takes a boxed value, of type `!eco.value`, and
produces the primitive it holds. The rules checked are stated in
`TestLogic.Generate.CodeGen.EcoUnboxSanity`.

The fixture is the set of source programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` gathers. Which case modules it includes,
and which it leaves out, is stated there.

What the tests establish:

  - `suite`: for each program in the catalogue,
    `TestLogic.TestPipeline.runToMlir` succeeds, and each `eco.unbox` in a
    top-level `func.func` of the generated MLIR has one operand and one result,
    the operand is defined in the function with type `!eco.value`, and the
    result type is `i1`, `i16`, `i64` or `f64`.

Among what is not tested:

  - programs outside the standard catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.EcoUnboxSanity exposing (expectEcoUnboxSanity)


{-| The `eco.unbox` type check applied to every program in the standard
catalogue, in one group.
-}
suite : Test
suite =
    Test.describe "CGEN_0E2: eco.unbox Sanity"
        [ StandardTestSuites.expectSuite expectEcoUnboxSanity "passes eco.unbox sanity invariant"
        ]
