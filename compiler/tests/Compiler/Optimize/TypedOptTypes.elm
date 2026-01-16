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
import Expect


{-| TOPT_001: Verify all expressions have types.
-}
expectAllExprsHaveTypes : Src.Module -> Expect.Expectation
expectAllExprsHaveTypes srcModule =
    -- TODO_TEST_LOGIC
    -- For each TypedOptimized.Expr variant:
    --   * Assert the last constructor argument is a Can.Type.
    --   * Implement typeOf via pattern-match, and test that for all expressions (after optimization),
    --     typeOf returns that last field.
    -- Oracle: No expression constructor missing a trailing type; typeOf is total and returns the stored type.
    Debug.todo "TypedOptimized expressions always carry types"


{-| TOPT_001: Verify all types are well-formed.
-}
expectTypesWellFormed : Src.Module -> Expect.Expectation
expectTypesWellFormed srcModule =
    -- TODO_TEST_LOGIC
    -- For each TypedOptimized.Expr, verify the attached Can.Type is well-formed:
    --   * No dangling type variable references.
    --   * All type constructors refer to defined types.
    --   * Type arities match definitions.
    -- Oracle: All types pass well-formedness checks.
    Debug.todo "TypedOptimized types are well-formed"
