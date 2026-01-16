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
import Expect


{-| Verify that all imports are properly resolved.
-}
expectImportsResolved : Src.Module -> Expect.Expectation
expectImportsResolved srcModule =
    -- TODO_TEST_LOGIC
    -- Build interface maps with/without specific modules and exposed symbols.
    -- Run Foreign.createInitialEnv and canonicalization; verify that:
    --   * Valid imports resolve and populate the environment.
    --   * Missing modules yield ImportNotFound.
    --   * Missing exposed values/types/ctors/operators yield ImportExposingNotFound.
    --   * Ambiguous imports between multiple modules produce the corresponding Ambiguous* errors.
    -- Oracle: Every import reference either resolves uniquely or yields the exact expected error kind.
    Debug.todo "Imports resolve to valid interfaces"
