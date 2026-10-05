module TestLogic.Canonicalize.GlobalNamesTest exposing (suite)

{-| Runs the global-name check on the `SourceIR` test programs, so that a
program canonicalized into a reference with an incomplete home fails a test
rather than going unnoticed into the later phases.

A reference's _home_ is the module it resolves to: a package author, a package
project and a module name. `TestLogic.Canonicalize.GlobalNames` owns the check
and states what it walks and what it skips; here it is enough that a home is
complete when none of those three parts is empty. A `VarKernel` reference,
which has no home, must have a kernel prefix of `Elm` or `Eco` and a non-empty
kernel module and name; `VarLocal` references are not checked.

`suite` has four parts:

  - Every program of `SourceIR.Suite.StandardTestSuites`, given to
    `expectGlobalNamesQualified`, which canonicalizes it, fails if
    canonicalization reports an error, and otherwise checks the homes in the
    result.
  - Every program of `SourceIR.TypeCheckFailsCases`, in the same way. No type
    checking runs here, so these programs must only canonicalize without error.
  - The canonical modules of `SourceIR.KernelCases`, given directly to
    `expectGlobalNamesQualifiedCanonical`. Their references are `VarKernel`
    and `VarLocal`, so this part checks the kernel prefix, module and name of
    each `VarKernel`.
  - The canonical modules of `SourceIR.ForeignCases`, given directly to
    `expectGlobalNamesQualifiedCanonical`, which checks the homes of the
    `VarForeign` references built into them.

Among what is not tested:

  - That a home names a module that exists, or the right one.
  - The canonicalizer's handling of the kernel and foreign references in
    `KernelCases` and `ForeignCases`. Those modules are built by hand and never
    canonicalized, so the last two parts check the hand-built homes and the
    walk, not the canonicalizer.
  - The programs of `SourceIR.CaseSafepointLeakCases`, which
    `StandardTestSuites` does not include.
  - The homes of types in annotations, and of anything in a module outside the
    definitions of its declarations, which the check does not walk.

-}

import SourceIR.ForeignCases as ForeignCases
import SourceIR.KernelCases as KernelCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)
import TestLogic.Canonicalize.GlobalNames exposing (expectGlobalNamesQualified, expectGlobalNamesQualifiedCanonical)


{-| The tests that the references the global-name check inspects carry a
complete home, in the four parts the module docstring lists.
-}
suite : Test
suite =
    Test.describe "Global names are fully qualified (CANON_001)"
        [ StandardTestSuites.expectSuite expectGlobalNamesQualified "has qualified global names"
        , TypeCheckFailsCases.expectSuite expectGlobalNamesQualified "has qualified global names"

        -- These two case modules build canonical modules, not source, so they take the variant that does not canonicalize.
        , KernelCases.expectSuite expectGlobalNamesQualifiedCanonical "has qualified global names"
        , ForeignCases.expectSuite expectGlobalNamesQualifiedCanonical "has qualified global names"
        ]
