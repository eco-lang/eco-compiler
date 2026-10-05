module TestLogic.Canonicalize.IdAssignmentTest exposing (suite)

{-| Runs the node-id check on the `SourceIR` test programs, so that a program
for which canonicalization gives the same id to two of the nodes the check
collects fails a test. Later phases attach information, such as an inferred
type, to a node by its id, and a shared id would mix that information up.

A _node id_ is the `id` in the `{ id, node }` record that wraps every
expression and pattern in the canonical AST.
`TestLogic.Canonicalize.IdAssignment` owns the check and states which ids it
collects and what it rejects; in short, it fails on a negative id,
a repeated expression id, a repeated pattern id, or an id used by both an
expression and a pattern, and it collects the ids of every expression and
pattern in a module's top-level declarations.

`suite` has four parts:

  - Every program of `SourceIR.Suite.StandardTestSuites`, given to
    `expectUniqueIds`, which canonicalizes it, fails if canonicalization
    reports an error, and otherwise checks the ids in the result.
  - Every program of `SourceIR.TypeCheckFailsCases`, in the same way. No type
    checking runs here, so these programs must only canonicalize without error.
  - The canonical modules of `SourceIR.KernelCases`, given directly to
    `expectUniqueIdsCanonical`.
  - The canonical modules of `SourceIR.ForeignCases`, given directly to
    `expectUniqueIdsCanonical`.

Among what is not tested:

  - Ids given by the canonicalizer to the kernel and foreign references of
    `KernelCases` and `ForeignCases`. Those modules are built by hand, with ids
    chosen by hand, and never canonicalized, so the last two parts check those
    choices, not the canonicalizer.
  - Anything outside a module's top-level declarations, which the check does
    not collect.
  - The programs of `SourceIR.CaseSafepointLeakCases`, which
    `StandardTestSuites` does not include.

-}

import SourceIR.ForeignCases as ForeignCases
import SourceIR.KernelCases as KernelCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)
import TestLogic.Canonicalize.IdAssignment exposing (expectUniqueIds, expectUniqueIdsCanonical)


{-| The tests that the node ids the check collects pass the node-id check, in
the four parts the module docstring lists.
-}
suite : Test
suite =
    Test.describe "Unique IDs for all nodes in Canonical form"
        [ StandardTestSuites.expectSuite expectUniqueIds "has unique IDs"
        , TypeCheckFailsCases.expectSuite expectUniqueIds "has unique IDs"

        -- These two case modules build canonical modules, not source, so they take the variant that does not canonicalize.
        , KernelCases.expectSuite expectUniqueIdsCanonical "has unique IDs"
        , ForeignCases.expectSuite expectUniqueIdsCanonical "has unique IDs"
        ]
