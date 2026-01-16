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
import Expect


{-| MONO_002: Verify no CNumber MVars remain at MLIR codegen entry.
-}
expectNoNumericPolymorphism : Src.Module -> Expect.Expectation
expectNoNumericPolymorphism srcModule =
    -- TODO_TEST_LOGIC
    -- At the boundary to MLIR generation, traverse all reachable MonoTypes and assert:
    --   * No MVar has a CNumber constraint.
    --   * Any such occurrence is reported as a compiler bug in tests.
    -- Oracle: All numeric polymorphism is fully resolved; remaining MVars are non-numeric only.
    Debug.todo "No CNumber MVar at MLIR codegen entry"


{-| MONO_008: Verify primitive numeric types are fixed in all calls.
-}
expectNumericTypesResolved : Src.Module -> Expect.Expectation
expectNumericTypesResolved srcModule =
    -- TODO_TEST_LOGIC
    -- At each specialized function call:
    --   * Unify the canonical function type with monomorphic argument MonoTypes.
    --   * Assert all primitive numeric types are concretely MInt or MFloat.
    --   * If a mismatch is detected, classify as a monomorphization bug and treat as test failure.
    -- Oracle: No unresolved or inconsistent numeric type at call sites.
    Debug.todo "Primitive numeric types are fixed in calls"
