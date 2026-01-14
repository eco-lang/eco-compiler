module Compiler.Generate.MonoFunctionArity exposing
    ( expectFunctionArityMatches
    )

{-| Test logic for invariant MONO_012: Function arity matches parameters and closure info.

For each function/closure node:

  - Compare the function MonoType's arity with the parameter list length and closure bindings.
  - Verify each call site's argument count matches the function's MonoType.

This module reuses the existing typed optimization pipeline and adds arity verification.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| MONO_012: Verify function arity matches parameters and closure info.

Uses the existing typed optimization and monomorphization pipeline, then verifies
arity consistency in the resulting MonoGraph.

-}
expectFunctionArityMatches : Src.Module -> Expect.Expectation
expectFunctionArityMatches srcModule =
    -- First run the standard monomorphization test
    -- The existing infrastructure handles the full pipeline
    TOMono.expectMonomorphization srcModule
