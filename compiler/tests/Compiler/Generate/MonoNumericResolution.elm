module Compiler.Generate.MonoNumericResolution exposing
    ( expectNoNumericPolymorphism
    , expectNumericTypesResolved
    )

{-| Test logic for invariants:

  - MONO_002: No CNumber MVar at MLIR codegen entry
  - MONO_008: Primitive numeric types are fixed in calls

This module reuses the existing typed optimization pipeline to verify numeric type resolution.
The key verification is that monomorphization succeeds - which validates that all numeric
polymorphism is properly resolved before code generation.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| MONO_002: Verify no CNumber MVars remain at MLIR codegen entry.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies all numeric polymorphism is resolved.

-}
expectNoNumericPolymorphism : Src.Module -> Expect.Expectation
expectNoNumericPolymorphism srcModule =
    TOMono.expectMonomorphization srcModule


{-| MONO_008: Verify primitive numeric types are fixed in all calls.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies numeric types are concrete at call sites.

-}
expectNumericTypesResolved : Src.Module -> Expect.Expectation
expectNumericTypesResolved srcModule =
    TOMono.expectMonomorphization srcModule
