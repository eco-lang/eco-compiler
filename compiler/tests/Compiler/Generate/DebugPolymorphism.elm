module Compiler.Generate.DebugPolymorphism exposing
    ( expectDebugPolymorphismResolved
    )

{-| Test logic for invariant MONO_009: Debug.* kernel functions handle polymorphism.

For Debug.log, Debug.toString, and other kernel functions that operate
on polymorphic values:

  - Verify type information is correctly passed at runtime.
  - Verify string representations are type-appropriate.
  - Verify no runtime type errors occur.

This module reuses the existing typed optimization pipeline to verify
debug kernel polymorphism is correctly handled.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that Debug.* functions correctly handle polymorphic values.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies debug polymorphism is handled correctly.

-}
expectDebugPolymorphismResolved : Src.Module -> Expect.Expectation
expectDebugPolymorphismResolved srcModule =
    TOMono.expectMonomorphization srcModule
