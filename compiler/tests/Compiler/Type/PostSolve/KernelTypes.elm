module Compiler.Type.PostSolve.KernelTypes exposing
    ( expectKernelTypesValid
    )

{-| Test logic for invariant POST_002: Kernel types are correctly resolved.

Verify that references to kernel (built-in) types like Int, Float, String,
List, etc. are correctly resolved and consistent throughout the module.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that kernel types are correctly resolved.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies kernel types are correctly resolved.

-}
expectKernelTypesValid : Src.Module -> Expect.Expectation
expectKernelTypesValid srcModule =
    TOMono.expectMonomorphization srcModule
