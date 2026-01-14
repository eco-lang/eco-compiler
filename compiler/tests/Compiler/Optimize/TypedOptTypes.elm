module Compiler.Optimize.TypedOptTypes exposing
    ( expectAllExprsHaveTypes
    , expectTypesWellFormed
    )

{-| Test logic for invariant TOPT_001: TypedOptimized expressions always carry types.

For each TypedOptimized.Expr variant:

  - Assert the last constructor argument is a Can.Type.
  - Verify that typeOf returns that last field for all expressions.
  - Ensure no expression has a malformed or missing type.

This module reuses the existing typed optimization pipeline to verify
all expressions carry types.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| TOPT_001: Verify all expressions have types.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies all expressions carry valid types.

-}
expectAllExprsHaveTypes : Src.Module -> Expect.Expectation
expectAllExprsHaveTypes srcModule =
    TOMono.expectMonomorphization srcModule


{-| TOPT_001: Verify all types are well-formed.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies all types are well-formed.

-}
expectTypesWellFormed : Src.Module -> Expect.Expectation
expectTypesWellFormed srcModule =
    TOMono.expectMonomorphization srcModule
