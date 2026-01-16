module Compiler.Generate.MonoLayoutIntegrity exposing
    ( expectCtorLayoutsConsistent
    , expectLayoutsCanonical
    , expectRecordAccessMatchesLayout
    , expectRecordTupleLayoutsComplete
    )

{-| Test logic for invariants:

  - MONO_006: Record and tuple layouts capture shape completely
  - MONO_007: Record access matches layout metadata
  - MONO_013: Constructor layouts define consistent custom types
  - MONO_014: Structurally equivalent layouts are canonical

This module reuses the existing typed optimization pipeline to verify layout integrity.
The key verification is that monomorphization succeeds - which validates that layouts
are properly computed and used.

-}

import Compiler.AST.Source as Src
import Expect


{-| MONO_006: Verify record and tuple layouts capture shape completely.
-}
expectRecordTupleLayoutsComplete : Src.Module -> Expect.Expectation
expectRecordTupleLayoutsComplete srcModule =
    -- TODO_TEST_LOGIC
    -- For every record/tuple type:
    --   * Inspect the associated layout's fieldCount, indices, and unboxedBitmap.
    --   * Reconstruct the logical field order and unboxing decisions from source types and compare.
    -- Oracle: Layout metadata matches the exact logical record/tuple structure;
    -- indices and unboxing flags are correct.
    Debug.todo "Record and tuple layouts capture shape completely"


{-| MONO_007: Verify record access matches layout metadata.
-}
expectRecordAccessMatchesLayout : Src.Module -> Expect.Expectation
expectRecordAccessMatchesLayout srcModule =
    -- TODO_TEST_LOGIC
    -- For each record field access/update:
    --   * Use the record value's MonoType to find its RecordLayout.
    --   * Verify the field index and isUnboxed flag used in the IR matches the layout's metadata.
    -- Oracle: No mismatch between record access operations and layout definitions.
    Debug.todo "Record access matches layout metadata"


{-| MONO_013: Verify constructor layouts define consistent custom types.
-}
expectCtorLayoutsConsistent : Src.Module -> Expect.Expectation
expectCtorLayoutsConsistent srcModule =
    -- TODO_TEST_LOGIC
    -- For each custom type and each constructor:
    --   * Verify CtorLayout field count and ordering match the constructor definition.
    --   * Assert unboxedBitmap matches which fields are unboxed primitives.
    --   * Check all construction and pattern matching nodes adhere to the same layout.
    -- Oracle: No discrepancy between constructor use sites and their layouts.
    Debug.todo "Constructor layouts define consistent custom types"


{-| MONO_014: Verify structurally equivalent layouts are canonical.
-}
expectLayoutsCanonical : Src.Module -> Expect.Expectation
expectLayoutsCanonical srcModule =
    -- TODO_TEST_LOGIC
    -- Search for record/tuple types that are structurally equivalent
    -- (same fields and unboxing decisions):
    --   * Check they either share the same layout identifier or produce layouts whose
    --     indices and unboxedBitmap are identical.
    -- Oracle: No spurious duplication of equivalent layouts; layout metadata is canonicalized.
    Debug.todo "Structurally equivalent layouts are canonical"
