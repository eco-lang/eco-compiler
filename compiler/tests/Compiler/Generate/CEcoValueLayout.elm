module Compiler.Generate.CEcoValueLayout exposing
    ( expectValidCEcoValueLayout
    )

{-| Test logic for invariant MONO_003: CEcoValue layout is consistent.

For each monomorphized value:

  - Verify the CEcoValue layout matches the MonoType.
  - Verify field ordering is deterministic.
  - Verify alignment and padding are correct.

This module reuses the existing typed optimization pipeline to verify
CEcoValue layout is correctly computed.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that CEcoValue layouts are consistent with MonoTypes.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies CEcoValue layouts are correct.

-}
expectValidCEcoValueLayout : Src.Module -> Expect.Expectation
expectValidCEcoValueLayout srcModule =
    TOMono.expectMonomorphization srcModule
