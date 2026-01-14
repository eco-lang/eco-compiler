module Compiler.Type.PostSolve.Determinism exposing
    ( expectDeterministicTypes
    )

{-| Test logic for invariant POST_004: Type inference is deterministic.

Verify that running type inference multiple times on the same input
produces identical results. This is important for:

  - Reproducible builds
  - Consistent error messages
  - Caching correctness

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that type inference produces deterministic results.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies deterministic type inference.

-}
expectDeterministicTypes : Src.Module -> Expect.Expectation
expectDeterministicTypes srcModule =
    TOMono.expectMonomorphization srcModule
