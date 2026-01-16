module Compiler.Type.PostSolve.NoSyntheticVars exposing
    ( expectNoSyntheticVars
    )

{-| Test logic for invariant POST_003: No synthetic type variables remain.

After solving, verify that no synthetic (unification) type variables
remain in the final types. All type variables should be either:

  - User-declared type variables in annotations
  - Generalized type variables from let-polymorphism

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that no unconstrained synthetic variables remain after PostSolve.
-}
expectNoSyntheticVars : Src.Module -> Expect.Expectation
expectNoSyntheticVars srcModule =
    -- TODO_TEST_LOGIC
    -- Scan NodeTypes for non-kernel expressions after PostSolve:
    --   * Assert all types contain no unconstrained synthetic vars.
    --   * For any placeholder kind that remain by design (kernel-related), assert they're
    --     limited to kernel expressions.
    -- Oracle: NodeTypes is fully concrete for non-kernel expressions;
    -- any remaining synthetic variables are flagged as a violation.
    Debug.todo "No unconstrained synthetic variables remain after PostSolve"
