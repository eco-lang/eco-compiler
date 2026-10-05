module TestLogic.LocalOpt.AnnotationsPreservedTest exposing (suite)

{-| Runs the annotation check of `TestLogic.LocalOpt.AnnotationsPreserved` on
every program in the standard catalogue, so that typed optimization is checked
for giving every top-level value an annotation, and keeping the type checker's,
on all of those programs rather than on a hand-picked few.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from the `SourceIR` case modules.

What the tests establish, for each program:

  - The check fails with the pipeline's message if running the program to the
    end of typed optimization returns an error.
  - Otherwise it fails if a value node of the program's local graph (a
    definition, a port, or a name a recursive group defines) has no entry in
    the graph's annotations, or if a name type checking annotated is missing
    from the graph's annotations or has a different scheme there.

Typed optimization starts the local graph's annotations from the type
checker's, so the second half of the last condition fails only if a later step
removes or replaces an entry.

Among what is not tested: whether an annotation of a node typed optimization
created is the right type for that node.

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
