module Compiler.Type.PostSolve.GroupBTypes exposing
    ( expectGroupBTypesValid
    )

{-| Test logic for invariant POST_001: GroupB types are fully resolved.

After solving, verify that all GroupB (mutually recursive) definitions
have fully resolved types with no remaining unification variables.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that Group B expressions get structural types.
-}
expectGroupBTypesValid : Src.Module -> Expect.Expectation
expectGroupBTypesValid srcModule =
    -- TODO_TEST_LOGIC
    -- Identify Group B expressions (lists, tuples, records, units, lambdas) whose pre-PostSolve
    -- solver types include unconstrained synthetic variables. After PostSolve:
    --   * Assert those entries are replaced with concrete Can.Type structures.
    --   * Reconstruct the type structurally from subexpression types and compare to PostSolve's result.
    -- Oracle: No Group B expression retains an unconstrained synthetic var;
    -- recomputed structural type matches PostSolve's.
    Debug.todo "Group B expressions get structural types"
