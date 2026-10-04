module TestLogic.Generate.CodeGen.CustomConstructionTest exposing (suite)

{-| This suite looks, across many programs, for an `eco.construct.custom` op
that lacks its `tag` or `size` attribute, whose `size` differs from its operand
count, or whose `constructor` attribute is `Cons` or `Nil`. It is the only
module that runs
`TestLogic.Generate.CodeGen.CustomConstruction.expectCustomConstruction`, so
without it that check would not run at all.

The fixture is the standard catalogue of test programs, as
`SourceIR.Suite.StandardTestSuites` describes it: the programs built by each of
the case modules it includes, some of them by fuzz tests, whose programs can
vary from run to run.

What the tests establish:

  - `suite` runs `expectCustomConstruction` on the programs in the
    catalogue. A program passes when it compiles to MLIR and
    every `eco.construct.custom` op in it has integer `tag` and `size`
    attributes, a `size` equal to its number of operands, and no `constructor`
    attribute equal to `Cons` or `Nil`.

Among what is not tested:

  - The value of `tag`, only its presence.
  - Whether the op builds a value of a built-in type other than `List`, such
    as `Maybe`: only the constructor names `Cons` and `Nil` are rejected, and
    an op with no `constructor` attribute is not checked for them.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CustomConstruction exposing (expectCustomConstruction)


{-| The group of tests that runs the `eco.construct.custom` attribute check on
the programs of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_020: Custom ADT Construction"
        [ StandardTestSuites.expectSuite expectCustomConstruction "passes custom construction invariant"
        ]
