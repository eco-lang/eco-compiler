module Compiler.Type.PostSolve.KernelTypes exposing
    ( expectKernelTypesValid
    )

{-| Test logic for invariant POST_002: Kernel types are correctly resolved.

Verify that references to kernel (built-in) types like Int, Float, String,
List, etc. are correctly resolved and consistent throughout the module.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that kernel function types are inferred from usage.
-}
expectKernelTypesValid : Src.Module -> Expect.Expectation
expectKernelTypesValid srcModule =
    -- TODO_TEST_LOGIC
    -- Build modules with kernel alias definitions referencing VarKernel and various usage forms
    -- (calls, ctors, binops, case branches). Run PostSolve and:
    --   * Verify the seeding from aliases.
    --   * Trace first-usage-wins scheme-to-type unification and confirm the resulting
    --     KernelTypeEnv matches the observed usage patterns.
    -- Oracle: Each (home, name) kernel pair has a consistent canonical function type;
    -- conflicting usages surface as bugs, not silent merges.
    Debug.todo "Kernel function types inferred from usage"
