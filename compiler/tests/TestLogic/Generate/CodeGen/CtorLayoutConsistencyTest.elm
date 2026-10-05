module TestLogic.Generate.CodeGen.CtorLayoutConsistencyTest exposing (suite)

{-| This suite looks, across many programs, for an `eco.construct.custom` op
whose `size` or `unboxed_bitmap` agrees with no constructor layout computed for
the constructor it names. It is the only module that runs
`TestLogic.Generate.CodeGen.CtorLayoutConsistency.expectCtorLayoutConsistency`,
so without it that check would not run at all.

The fixture is the standard catalogue of test programs, as
`SourceIR.Suite.StandardTestSuites` describes it: the programs built by each of
the case modules it includes, some of them by fuzz tests, whose programs can
vary from run to run.

What the tests establish:

  - `suite` runs `expectCtorLayoutConsistency` on the programs in the
    catalogue. A program passes when it compiles to MLIR and every
    `eco.construct.custom` op in it has a `constructor` name and integer
    `tag`, `size` and `unboxed_bitmap` attributes, and, where the
    constructor shapes (each a constructor's name, tag and field types)
    recorded in the monomorphized graph include some with the op's
    constructor name, one of them has the op's tag and the `size` and
    `unboxed_bitmap` match the layout computed for one with that name and tag.

Among what is not tested:

  - Which specialisation of a constructor an op builds: the size and bitmap
    of another specialisation of the same constructor pass.
  - An op whose constructor name has no shape in the graph.
  - Custom values built in any other way than by `eco.construct.custom`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CtorLayoutConsistency exposing (expectCtorLayoutConsistency)


{-| The group of tests that runs the constructor-layout check on the programs
of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_014: Ctor Layout Consistency"
        [ StandardTestSuites.expectSuite expectCtorLayoutConsistency "passes ctor layout consistency invariant"
        ]
