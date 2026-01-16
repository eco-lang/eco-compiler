module Compiler.Generate.MonoFunctionArity exposing
    ( expectFunctionArityMatches
    )

{-| Test logic for invariant MONO_012: Function arity matches parameters and closure info.

For each function/closure node:

  - Compare the function MonoType's arity with the parameter list length and closure bindings.
  - Verify each call site's argument count matches the function's MonoType.

This module reuses the existing typed optimization pipeline and adds arity verification.

-}

import Compiler.AST.Source as Src
import Expect


{-| MONO_012: Verify function arity matches parameters and closure info.
-}
expectFunctionArityMatches : Src.Module -> Expect.Expectation
expectFunctionArityMatches srcModule =
    -- TODO_TEST_LOGIC
    -- For each function/closure node:
    --   * Compare the function MonoType's arity with the parameter list length and closure bindings.
    --   * Verify each call site's argument count matches the function's MonoType
    --     (allowing partial application where supported).
    -- Oracle: All call sites are well-formed w.r.t. MonoType; no over/under-application.
    Debug.todo "Function arity matches parameters and closure info"
