module TestLogic.Generate.CodeGen.DestructorTypeProjectionTest exposing (suite)

{-| These tests look in generated MLIR for a sign that pattern matching read a
field out of a custom-type value at the wrong type: the field comes out boxed,
as an `!eco.value`, and that result is then unboxed. The rule this breaks is
called `CGEN_004` in the test names and failure messages: a field read out of a
constructor should come out at its own specialised type, so an `Int` field
should come out as an `i64`.

The pattern looked for is defined in
`TestLogic.Generate.CodeGen.DestructorTypeProjection`, which calls it a
_spurious unbox_: an `eco.unbox` to `i64`, `f64` or `i32` whose operand is
defined by an `eco.project.custom`, the op that reads one field of a
custom-type value, in the same function.

The fixture is the standard catalogue of test programs that
`SourceIR.Suite.StandardTestSuites` runs. Among them, `SourceIR.MaybeResultCases`
reads the `Int` out of a program's own `Maybe` and `Result` (one `case` nested
in another), and `SourceIR.WideObjectCases` reads field 24 of 25-field
constructors (an `Int`, a `String`, and a type variable used at `Int`) and
field 27 of a 28-field record.

What the tests establish:

  - `standardTests`: every program in the standard catalogue compiles, and
    its generated MLIR holds no spurious unbox.

The result type at which a field of a wide object is projected is pinned for
particular programs by the unit test
`Compiler.GenerateMlir.PatternsWideFieldProjectionTest`.

Among what is not tested: the result type the projection declares; that a
program holds any `eco.project.custom` at all, so a program whose match is
optimised away passes; and the value `testValue` computes, since no program is
run.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.DestructorTypeProjection exposing (expectDestructorTypeProjection)


{-| The whole suite: `standardTests`.
-}
suite : Test
suite =
    Test.describe "CGEN_004: Destructor Type Projection"
        [ standardTests
        ]


{-| The tests that run `expectDestructorTypeProjection` on every program in the
standard catalogue. A program fails when it does not compile or when its
generated MLIR holds any spurious unbox.
-}
standardTests : Test
standardTests =
    Test.describe "Standard test suites"
        [ StandardTestSuites.expectSuite expectDestructorTypeProjection "passes destructor type projection invariant"
        ]
