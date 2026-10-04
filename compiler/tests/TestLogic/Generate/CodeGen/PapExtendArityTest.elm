module TestLogic.Generate.CodeGen.PapExtendArityTest exposing (suite)

{-| These tests run the `eco.papExtend` remaining-arity check on the standard
catalogue of test programs, so that the code generator recording on a closure
application the wrong number of arguments still awaited is caught on any of
those programs, not only on a hand-picked few.

A partial application object (PAP) is a closure that holds some of a function's
arguments and waits for the rest. `eco.papCreate` builds one, and
`eco.papExtend` applies one to further arguments, its new arguments. A PAP's
remaining arity is how many arguments it still needs before its function runs.
The `remaining_arity` attribute of an `eco.papExtend` is the remaining arity of
the PAP it extends before this application, not after it.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites.expectSuite`
collects from the `SourceIR` case modules. The check is
`TestLogic.Generate.CodeGen.PapExtendArity.expectPapExtendArity`, whose module
docstring gives the rules, their order and their exceptions in full.

What the tests establish:

  - `suite`: for each catalogue program, the program compiles to MLIR with
    `runToMlir`, and no `eco.papExtend` in the result lacks `remaining_arity`
    (unless its `_call_kind` is `generic_apply` or `segmentation_unknown`), has
    a negative one, has no operands, has a `remaining_arity` different from the
    remaining arity of the PAP it extends, or is given more new arguments than
    its `remaining_arity`. A failing test reports only the first violation
    found.

Among what is not tested: the last two rules are skipped when the PAP being
extended has no remaining arity recorded in the same top-level op, as for a
block argument, and the result type of an `eco.papExtend` is not examined.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendArity exposing (expectPapExtendArity)


{-| The test group that applies the `eco.papExtend` remaining-arity check to
each program in the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_052: PapExtend remaining_arity calculation"
        [ StandardTestSuites.expectSuite expectPapExtendArity "passes papExtend remaining_arity invariant"
        ]
