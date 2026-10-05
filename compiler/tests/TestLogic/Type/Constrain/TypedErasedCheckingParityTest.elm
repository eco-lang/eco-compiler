module TestLogic.Type.Constrain.TypedErasedCheckingParityTest exposing (suite)

{-| Runs the project's catalogues of test programs through both type-checking
paths, so that a program the two paths treat differently shows up as a failing
test.

The compiler can type-check a module on an _erased path_ or a _typed path_,
which differ in how constraints are generated and solved; the two paths, and
what counts as agreement between them, are as
`TestLogic.Type.Constrain.TypedErasedCheckingParity` describes. In short, a
program passes when both paths accept it with the same annotations and the
typed path gives every expression and pattern a type, or when both reject it
with matching errors.

The fixture is four case modules. None of them asserts anything itself: each
applies the expectation given to it to every program it builds.

  - `SourceIR.Suite.StandardTestSuites` passes the expectation on to its
    catalogue of source programs, which are checked with
    `expectEquivalentTypeChecking`. That canonicalizes each program first, and
    a program that fails to canonicalize fails its test.
  - `SourceIR.TypeCheckFailsCases` holds source programs that each contain a
    type error, checked with `expectEquivalentRejection`: both paths must
    reject each of them, with matching errors.
  - `SourceIR.KernelCases` and `SourceIR.ForeignCases` build canonical modules
    by hand, holding kernel references and references to values of another
    module respectively. There is no source to canonicalize, so they are checked
    with `expectEquivalentTypeCheckingCanonical`.

What the tests establish:

  - Under "check equivalently", each test that the case modules of
    `StandardTestSuites` build checks its programs as above.
  - "Type check failure tests are rejected equivalently" is one test over
    every program in `TypeCheckFailsCases`. It fails on the first program that fails
    the expectation, and names it.
  - "VarKernel expressions check equivalently" and "VarForeign expressions
    check equivalently" are one test each over every module in `KernelCases`
    and in `ForeignCases`, likewise failing on the first module that fails.

Among what is not tested: whether a `StandardTestSuites` program is accepted,
since two matching rejections pass as surely as two acceptances; the programs
of `SourceIR.CaseSafepointLeakCases`, which `StandardTestSuites` does not
include; and whatever `TypedErasedCheckingParity` lists as outside its
comparison, such as the node types themselves.

-}

import SourceIR.ForeignCases as ForeignCases
import SourceIR.KernelCases as KernelCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)
import TestLogic.Type.Constrain.TypedErasedCheckingParity
    exposing
        ( expectEquivalentRejection
        , expectEquivalentTypeChecking
        , expectEquivalentTypeCheckingCanonical
        )


{-| The parity tests: the four case suites, each run through the parity
expectation that matches the kind of module it builds.
-}
suite : Test
suite =
    Test.describe "Type solver constrain and constrainWithIds type check equivalently"
        [ StandardTestSuites.expectSuite expectEquivalentTypeChecking "check equivalently"
        , TypeCheckFailsCases.expectSuite expectEquivalentRejection "are rejected equivalently"

        -- These two build canonical modules, not source, so they take the canonical expectation.
        , KernelCases.expectSuite expectEquivalentTypeCheckingCanonical "check equivalently"
        , ForeignCases.expectSuite expectEquivalentTypeCheckingCanonical "check equivalently"
        ]
