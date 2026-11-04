module TestLogic.Canonicalize.ImportResolutionTest exposing (suite)

{-| Tests invariant CANON\_004 on the standard catalogue of test programs:
every reference a module takes from another module resolves to a definition
that module's interface provides, so that a change which resolved an imported
name to the wrong module, name, constructor or operator would be noticed.

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.Canonicalize.ImportResolution.expectImportsResolved`, which runs
it through PostSolve with `TestLogic.TestPipeline.runToPostSolve` and checks
every reference to another module against that module's mock interface, as
its docstring states in full:

  - a `VarForeign` names a value of the interface, with its annotation and
    the interface's package;
  - a `VarCtor` of another module names a constructor of one of the
    interface's custom types at its index, or a record type alias;
  - a `VarOperator` or `Binop` names an operator of the interface and carries
    the function that operator stands for.

The catalogue includes `SourceIR.ImportResolutionCases`, the programs this
check was first written for.

Among what is not tested: patterns, type annotations, `VarDebug` and
`VarKernel` references, and modules whose resolution should fail.

It also runs over the programs of `SourceIR.MainFailsCases`, which typed
optimization rejects, and those of `SourceIR.MonoFailsCases`
(`expectBeforeMonoSuite`), which monomorphization rejects: every stage this
check looks at accepts them, and they hold what the standard catalogue cannot,
such as polymorphic recursion over a non-regular type.

-}

import SourceIR.MainFailsCases as MainFailsCases
import SourceIR.MonoFailsCases as MonoFailsCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Canonicalize.ImportResolution exposing (expectImportsResolved)


{-| `expectImportsResolved` over every program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "Import resolution produces valid references (CANON_004)"
        [ StandardTestSuites.expectSuite expectImportsResolved "resolves its imported names"
        , MainFailsCases.expectSuite expectImportsResolved "resolves its imported names"
        , MonoFailsCases.expectBeforeMonoSuite expectImportsResolved "resolves its imported names"
        ]
