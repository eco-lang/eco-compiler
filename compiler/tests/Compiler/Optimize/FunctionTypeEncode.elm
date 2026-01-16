module Compiler.Optimize.FunctionTypeEncode exposing
    ( expectFunctionTypesEncoded
    )

{-| Test logic for invariant TOPT_005: Function expressions encode full function type.

For every function expression in TypedOptimized:

  - Extract its parameter (Name, Can.Type) list and result Can.Type.
  - Compute the corresponding curried TLambda chain.
  - Assert that the expression's own attached Can.Type equals that TLambda type.

This module reuses the existing typed optimization pipeline to verify
function types are properly encoded.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that all function expressions have correctly encoded function types.
-}
expectFunctionTypesEncoded : Src.Module -> Expect.Expectation
expectFunctionTypesEncoded srcModule =
    -- TODO_TEST_LOGIC
    -- For every function expression in TypedOptimized:
    --   * Extract its parameter (Name, Can.Type) list and result Can.Type.
    --   * Compute the corresponding curried TLambda chain.
    --   * Assert that the expression's own attached Can.Type equals that TLambda type.
    -- Oracle: Function types are internally consistent; arity and parameter/result types
    -- always match the TLambda-encoded type.
    Debug.todo "Function expressions encode full function type"
