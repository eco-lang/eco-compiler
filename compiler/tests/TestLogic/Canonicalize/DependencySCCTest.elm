module TestLogic.Canonicalize.DependencySCCTest exposing (suite)

{-| Tests invariant CANON\_005 on the standard catalogue of test programs: the
canonicalizer groups a module's top-level definitions into the strongly
connected components of their dependency graph, each component after the ones
it depends on.

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.Canonicalize.DependencySCC.expectValidSCCs`, which runs it
through PostSolve with `TestLogic.TestPipeline.runToPostSolve` and walks the
canonical declarations. For each program the test establishes, as that
module's docstring states in full:

  - it canonicalizes and type checks;
  - no `Declare`d definition depends on itself;
  - no definition depends on one declared in a later component;
  - a recursive group of one definition depends on itself, and a larger one
    is strongly connected through dependencies within the group.

The catalogue includes `SourceIR.DependencySCCCases`, the programs this check
was first written for; the grouping expected for each of those is pinned in
`Compiler.Canonicalize.DependencySCCTest`.

Among what is not tested: the relative order of components that do not depend
on each other, and dependencies through ports or effect managers.

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
import TestLogic.Canonicalize.DependencySCC exposing (expectValidSCCs)


{-| `expectValidSCCs` over every program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "Dependency SCCs are correctly computed (CANON_005)"
        [ StandardTestSuites.expectSuite expectValidSCCs "has valid dependency SCCs"
        , MainFailsCases.expectSuite expectValidSCCs "has valid dependency SCCs"
        , MonoFailsCases.expectBeforeMonoSuite expectValidSCCs "has valid dependency SCCs"
        ]
