module TestLogic.Generate.CodeGen.PapArityConsistencyTest exposing (suite)

{-| These tests make it a failure when the code generator records the wrong
`arity` on an `eco.papCreate`, the op that builds a partial application. The
check compares that `arity` with the parameter count of the function the op
targets, as `TestLogic.Generate.CodeGen.PapArityConsistency` describes,
including which function is the target when the closure has captured values.

The programs are the standard catalogue of `SourceIR` test programs, gathered
by `SourceIR.Suite.StandardTestSuites`. Most are fixed; some, from its fuzzing
case modules, can vary from run to run.

What the tests establish:

  - `suite` compiles each program to MLIR and checks, with
    `expectPapArityConsistency`, that compilation succeeds and that no
    `eco.papCreate` whose target is a top-level `func.func` of the module has
    an `arity` different from that function's parameter count.

Among what is not tested: an `eco.papCreate` lacking `arity` or `function`, or
whose target is not a top-level `func.func` of the module; and programs from
the `SourceIR` case modules that `StandardTestSuites` leaves out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapArityConsistency exposing (expectPapArityConsistency)


{-| The partial-application arity check, applied to every program of the
standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_051: PapCreate arity matches function parameters"
        [ StandardTestSuites.expectSuite expectPapArityConsistency "passes papCreate arity consistency invariant"
        ]
