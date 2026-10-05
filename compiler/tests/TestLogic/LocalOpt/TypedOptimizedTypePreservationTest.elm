module TestLogic.LocalOpt.TypedOptimizedTypePreservationTest exposing (suite)

{-| Typed optimization stores a type on every expression it produces, and the
monomorphizer reads those stored types when it specializes the program. These
tests check the stored types of every program in the standard test suite.

The programs are those that `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from the `SourceIR` case modules. Each one is given to
`TestLogic.LocalOpt.TypePreservation.expectTypePreservation`, which runs it
through typed optimization in the test pipeline and compares types in the
resulting local graph. That module's docstring states the comparison in full.
Most case modules run their programs through `Compiler.BulkCheck.bulkCheck`,
which stops at the first failing program, so a failure hides any later one in
the same case module.

What `suite` establishes, for each program it reaches:

  - Typed optimization completes.
  - In the expressions the check visits, every local variable use, and every
    reference to a member of a recursive group, has the type recorded where
    the name is bound.
  - Every kernel reference it visits has the type of that kernel's entry in
    the kernel type environment.
  - Every case branch it visits, whether held inline in the decision tree or
    reached by a jump, has the type of the case.
  - Every literal it visits other than an `Int` has its fixed type: `()`,
    `Basics.Bool`, `Basics.Float`, `Char.Char` or `String.String`.

Among what is not tested: the types of `Int` literals, of global references,
of functions, calls, `let`, `if` and destructuring. A local variable or kernel
reference with no entry in the check's environment passes.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.TypePreservation exposing (expectTypePreservation)


{-| The test group that applies `expectTypePreservation` to every program of
the standard test suite.
-}
suite : Test
suite =
    Test.describe "TypedOptimized type preservation (TOPT_004)"
        [ StandardTestSuites.expectSuite expectTypePreservation "preserves types"
        ]
