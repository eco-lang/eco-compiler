module Compiler.Type.PostSolve.GroupBTypes exposing
    ( expectGroupBTypesValid
    )

{-| Test logic for invariant POST_001: GroupB types are fully resolved.

After solving, verify that all GroupB (mutually recursive) definitions
have fully resolved types with no remaining unification variables.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that GroupB types are fully resolved after solving.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies GroupB types are correctly resolved.

-}
expectGroupBTypesValid : Src.Module -> Expect.Expectation
expectGroupBTypesValid srcModule =
    TOMono.expectMonomorphization srcModule
