module Compiler.Generate.MonoTypeShape exposing
    ( expectMonoTypesFullyElaborated
    )

{-| Test logic for invariant MONO_001: MonoTypes are fully elaborated.

At all stages past monomorphization, every type has a concrete MonoType shape:
MInt, MFloat, MBool, MChar, MString, MUnit, MList, MTuple, MRecord, MCustom,
MFunction. MVar should only appear with constraint CEcoValue.

This module reuses the existing typed optimization pipeline to verify
that monomorphization produces valid MonoTypes.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| MONO_001: Verify all MonoTypes are fully elaborated.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies MonoTypes are properly elaborated.

-}
expectMonoTypesFullyElaborated : Src.Module -> Expect.Expectation
expectMonoTypesFullyElaborated srcModule =
    TOMono.expectMonomorphization srcModule
