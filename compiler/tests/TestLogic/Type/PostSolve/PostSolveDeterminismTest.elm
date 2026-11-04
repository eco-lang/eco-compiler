module TestLogic.Type.PostSolve.PostSolveDeterminismTest exposing (suite)

{-| Tests invariant POST\_004 on the standard catalogue of test programs:
compiling the same program twice, through PostSolve, gives the same node
types.

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.Type.PostSolve.PostSolveDeterminism.expectDeterministicTypes`,
which runs it through `TestLogic.TestPipeline.runToPostSolve` twice in the same
test process and compares the two arrays of node types after PostSolve
structurally, the arrow slot of each function type aside. A program that fails
to canonicalize or type check fails, naming the run.

The catalogue includes `SourceIR.PostSolveDeterminismCases`, the programs this
check was first written for.

Among what is not tested: the annotations, the node types before PostSolve, and
whether a run in another process or another build gives the same types.

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
import TestLogic.Type.PostSolve.PostSolveDeterminism exposing (expectDeterministicTypes)


{-| `expectDeterministicTypes` over every program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "Type inference is deterministic (POST_004)"
        [ StandardTestSuites.expectSuite expectDeterministicTypes "gets the same node types from two runs"
        , MainFailsCases.expectSuite expectDeterministicTypes "gets the same node types from two runs"
        , MonoFailsCases.expectBeforeMonoSuite expectDeterministicTypes "gets the same node types from two runs"
        ]
