module TestLogic.Generate.CodeGen.PapExtendResultTest exposing (suite)

{-| Runs the `eco.papExtend` result check on every program in the standard
catalogue, so that an `eco.papExtend` op compiled from one of them with other
than one result, with a result type outside those listed below, or without a
`remaining_arity` attribute where one is required, fails a test.

A _partial application_ (PAP) is a function value together with the arguments
it has been given so far, and an `eco.papExtend` op gives a PAP more arguments.
The rules each such op is held to are those
`TestLogic.Generate.CodeGen.PapExtendResult.expectPapExtendResult` states.

The programs are the Elm source programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers from its case modules.

`suite` establishes, for each of those programs, that it compiles to MLIR and
that every `eco.papExtend` op in the result has exactly one result, of type
`!eco.value`, `i1`, `i16`, `i64` or `f64`, and carries an integer
`remaining_arity` attribute unless its `_call_kind` is `generic_apply` or
`segmentation_unknown`.

Among what is not tested: the value of `remaining_arity`, and whether a typed
result is the return type of the function being applied.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendResult exposing (expectPapExtendResult)


{-| The `eco.papExtend` result check applied to every program in the standard
catalogue, as one group of tests.
-}
suite : Test
suite =
    Test.describe "CGEN_034: PapExtend Result Type"
        [ StandardTestSuites.expectSuite expectPapExtendResult "passes papExtend result invariant"
        ]
