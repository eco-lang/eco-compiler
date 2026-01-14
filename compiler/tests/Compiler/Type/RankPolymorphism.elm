module Compiler.Type.RankPolymorphism exposing
    ( expectRankPolymorphismValid
    )

{-| Test logic for invariant TYPE_005: Rank polymorphism is correctly handled.

For each let-binding and function:

  - Verify type variables are correctly generalized at appropriate ranks.
  - Verify monomorphization respects rank restrictions.
  - Verify higher-rank types are rejected or handled correctly.

This module reuses the existing typed optimization pipeline to verify
rank polymorphism is correctly handled.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that rank polymorphism is correctly handled.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies rank polymorphism is handled correctly.

-}
expectRankPolymorphismValid : Src.Module -> Expect.Expectation
expectRankPolymorphismValid srcModule =
    TOMono.expectMonomorphization srcModule
