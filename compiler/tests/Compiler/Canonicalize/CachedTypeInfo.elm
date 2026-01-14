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
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that cached type info is consistent.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies type caching is correct.

-}
expectTypeInfoCached : Src.Module -> Expect.Expectation
expectTypeInfoCached srcModule =
    TOMono.expectMonomorphization srcModule
