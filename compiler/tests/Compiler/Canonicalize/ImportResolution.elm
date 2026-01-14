module Compiler.Canonicalize.ImportResolution exposing
    ( expectImportsResolved
    )

{-| Test logic for invariant CANON_004: Import resolution produces valid references.

For each import statement:

  - Verify the imported module exists in the dependency graph.
  - Verify all explicitly imported values/types exist in the target module's exports.
  - Verify qualified references resolve to valid exported symbols.

This module reuses the existing typed optimization pipeline to verify
import resolution works correctly.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that all imports are properly resolved.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies all imports are correctly resolved.

-}
expectImportsResolved : Src.Module -> Expect.Expectation
expectImportsResolved srcModule =
    TOMono.expectMonomorphization srcModule
