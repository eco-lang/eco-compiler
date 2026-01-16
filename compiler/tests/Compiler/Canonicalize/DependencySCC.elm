module Compiler.Canonicalize.DependencySCC exposing
    ( expectValidSCCs
    )

{-| Test logic for invariant CANON_005: Dependency SCCs are correctly computed.

For the SCC analysis of value definitions:

  - Verify all definitions in an SCC have mutual dependencies.
  - Verify definitions in different SCCs have acyclic dependencies.
  - Verify topological ordering respects dependency order.

This module reuses the existing typed optimization pipeline to verify
SCC computation works correctly.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that SCCs are correctly computed.
-}
expectValidSCCs : Src.Module -> Expect.Expectation
expectValidSCCs srcModule =
    -- TODO_TEST_LOGIC
    -- For a variety of modules, build the value dependency graph, run Graph.stronglyConnComp, and:
    --   * Verify SCC grouping matches direct dependencies (unit tests).
    --   * Create non-terminating recursive definitions and mutually recursive groups;
    --     assert canonicalization reports RecursiveDecl or RecursiveLet.
    --   * Create legal recursion (e.g. functions using themselves in arguments) and assert
    --     they are grouped but not rejected.
    -- Oracle: SCC partitions are deterministic and error classification between legal recursion
    -- and non-terminating cycles is correct.
    Debug.todo "Dependency SCCs detect recursion correctly"
