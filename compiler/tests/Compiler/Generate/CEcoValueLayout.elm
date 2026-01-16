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
import Expect


{-| Verify that CEcoValue MVars do not affect layout.
-}
expectValidCEcoValueLayout : Src.Module -> Expect.Expectation
expectValidCEcoValueLayout srcModule =
    -- TODO_TEST_LOGIC
    -- For every MVar with CEcoValue:
    --   * Check that its usage appears only in positions that do not impact layout/calling convention
    --     (e.g., ECO-only metadata).
    --   * Assert that record/tuple/ctor layouts and MLIR signatures are identical under any
    --     substitution of concrete source types for those vars.
    -- Oracle: Changing CEcoValue type arguments does not change runtime layout or calling convention;
    -- tests via differential substitution.
    Debug.todo "CEcoValue MVars do not affect layout"
