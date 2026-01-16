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
import Expect


{-| MONO_001: Verify all MonoTypes are fully elaborated.
-}
expectMonoTypesFullyElaborated : Src.Module -> Expect.Expectation
expectMonoTypesFullyElaborated srcModule =
    -- TODO_TEST_LOGIC
    -- Inspect MonoTypes in the monomorphized IR:
    --   * Confirm that source-level types are represented as MInt, MFloat, MList, MTuple,
    --     MRecord, MCustom, or MFunction.
    --   * Confirm the only remaining generic vars are MVar with an attached Constraint
    --     (CEcoValue or CNumber, etc.).
    -- Oracle: No other kind of partially inferred or unspecialized type representation
    -- survives at this phase.
    Debug.todo "MonoType encodes fully elaborated runtime shapes"
