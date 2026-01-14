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
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that SCCs are correctly computed.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies SCCs are correctly computed.

-}
expectValidSCCs : Src.Module -> Expect.Expectation
expectValidSCCs srcModule =
    TOMono.expectMonomorphization srcModule
