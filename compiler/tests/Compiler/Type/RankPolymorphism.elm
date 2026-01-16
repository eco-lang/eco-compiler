module Compiler.Type.RankPolymorphism exposing
    ( expectRankPolymorphismValid
    )

{-| Test logic for invariant TYPE_005: Rank polymorphism is correctly handled.

For each let-binding and function:

  - Verify type variables are correctly generalized at appropriate ranks.
  - Verify monomorphization respects rank restrictions.
  - Verify higher-rank types are rejected or handled correctly.

This module reuses the existing typed optimization pipeline to verify
rank polymorphism is correctly handled.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that rank-based let-polymorphism is enforced.
-}
expectRankPolymorphismValid : Src.Module -> Expect.Expectation
expectRankPolymorphismValid srcModule =
    -- TODO_TEST_LOGIC
    -- Construct nested lets that should or should not generalize (e.g., classic ML rank examples,
    -- value restriction style cases). Inspect rank pools:
    --   * Ensure only variables at the correct rank are quantified.
    --   * Younger variables are frozen or promoted according to rules.
    --   * Unsound polymorphism across scopes does not appear in inferred schemes.
    -- Oracle: Resulting type schemes match expected rank-based polymorphism;
    -- attempts to exploit unsound generalization fail.
    Debug.todo "Rank-based let-polymorphism is enforced"
