module TestLogic.LocalOpt.AnnotationsPreservedTest exposing (suite)

{-| Runs the annotation check of `TestLogic.LocalOpt.AnnotationsPreserved` on
every program in the standard catalogue, so that typed optimization is checked
for keeping the type annotation of each top-level name on all of those programs
rather than on a hand-picked few.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from the `SourceIR` case modules.

What the tests establish, for each program:

  - The check fails with the pipeline's message if running the program to the
    end of typed optimization returns an error. Otherwise it fails if a name
    that type checking annotated has no entry in the annotations of the
    program's local graph.

As `TestLogic.LocalOpt.AnnotationsPreserved` describes, typed optimization
starts the local graph's annotations from the ones being checked, so the second
condition cannot fail. In effect the check passes on a program when typed
optimization succeeds on it.

Among what is not tested: whether an annotation in the local graph has the same
type as the one type checking gave; and names in the local graph that type
checking did not annotate.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.AnnotationsPreserved exposing (expectAnnotationsPreserved)


{-| The annotation check applied to every standard program, gathered in one
group.
-}
suite : Test
suite =
    Test.describe "Top-level annotations preserved in local graph (TOPT_003)"
        [ StandardTestSuites.expectSuite expectAnnotationsPreserved "has preserved annotations"
        ]
