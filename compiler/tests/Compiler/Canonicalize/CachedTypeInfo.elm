module Compiler.Canonicalize.CachedTypeInfo exposing
    ( expectTypeInfoCached
    )

{-| Test logic for invariant CANON_006: Cached type info matches source.

For each cached type annotation or inferred type:

  - Verify the cached type matches what would be freshly computed.
  - Verify type variables are consistently named.
  - Verify no stale type information persists after edits.

This module reuses the existing typed optimization pipeline to verify
type caching works correctly.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that cached type info is consistent.
-}
expectTypeInfoCached : Src.Module -> Expect.Expectation
expectTypeInfoCached srcModule =
    -- TODO_TEST_LOGIC
    -- For nodes VarForeign, VarCtor, VarDebug, VarOperator, and Binop, and patterns PCtor / PatternCtorArg:
    --   * Assert their cached Can.Annotation / Can.Type fields are present and consistent
    --     with the canonical type environment.
    --   * Randomly pick such nodes, recompute types via interface lookup, and compare
    --     with cached types.
    -- Oracle: No mismatch between cached types and environment-derived types;
    -- missing caches fail the test.
    Debug.todo "Cached type info for special vars and patterns"
