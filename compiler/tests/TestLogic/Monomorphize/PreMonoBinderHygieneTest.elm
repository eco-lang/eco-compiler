module TestLogic.Monomorphize.PreMonoBinderHygieneTest exposing (suite)

{-| Runs the binder-capture check of `TestLogic.Monomorphize.PreMonoBinderHygiene`
over the standard catalogue of test programs, so that a pre-monomorphization
pass that binds a local name already in scope is looked for in many kinds of
program, not only in the one fixture of
`Compiler.PreMono.InlineSimplifyDestructCaptureTest`.

_Binder capture_ is a binder in a definition's body whose name an enclosing
scope of that body already binds, so that the inner binder shadows the outer.
Elm forbids shadowing, so only a rewrite can introduce one; the pre-mono
inliner, which copies one body into another, is the pass most likely to. The
checker's module docstring defines binders and scopes and says what it does not
check.

The fixture is every program that `SourceIR.Suite.StandardTestSuites` passes to
its caller's expectation.

What the test establishes:

  - `"has no binder capture after the pre-mono passes"`: for each program,
    `expectPreMonoBinderHygiene` runs `Compiler.Pipeline.Steps.preMono` on its
    prepared graph under the production configuration and again with the
    pre-mono inliner switched on, and finds no captured binder in either
    result.

Among what is not tested: configurations with other inliner thresholds or
round limits, and the post-monomorphization inliner.

It also runs over the programs of `SourceIR.MonoFailsCases`
(`expectBeforeMonoSuite`), which monomorphization rejects: every stage this
check looks at accepts them, and they hold what the standard catalogue cannot,
such as polymorphic recursion over a non-regular type.

-}

import SourceIR.MonoFailsCases as MonoFailsCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.PreMonoBinderHygiene exposing (expectPreMonoBinderHygiene)


{-| The binder-capture check over every standard test program.
-}
suite : Test
suite =
    Test.describe "Pre-mono binder hygiene"
        [ StandardTestSuites.expectSuite expectPreMonoBinderHygiene "has no binder capture after the pre-mono passes"
        , MonoFailsCases.expectBeforeMonoSuite expectPreMonoBinderHygiene "has no binder capture after the pre-mono passes"
        ]
