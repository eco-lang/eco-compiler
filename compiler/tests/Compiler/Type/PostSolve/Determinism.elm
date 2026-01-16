module Compiler.Type.PostSolve.Determinism exposing
    ( expectDeterministicTypes
    )

{-| Test logic for invariant POST_004: Type inference is deterministic.

Verify that running type inference multiple times on the same input
produces identical results. This is important for:

  - Reproducible builds
  - Consistent error messages
  - Caching correctness

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that PostSolve is deterministic for Group B and kernels.
-}
expectDeterministicTypes : Src.Module -> Expect.Expectation
expectDeterministicTypes srcModule =
    -- TODO_TEST_LOGIC
    -- Given the same canonical module and initial solver-produced NodeTypes:
    --   * Run PostSolve multiple times and on different machines/build variants.
    --   * Assert the resulting fixed NodeTypes and KernelTypeEnv are byte-for-byte identical
    --     (or structurally equal).
    -- Oracle: No nondeterminism in PostSolve outputs; hashed summaries remain stable across runs.
    Debug.todo "PostSolve is deterministic for Group B and kernels"
