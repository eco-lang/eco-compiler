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
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Verify that no synthetic type variables remain after solving.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies no synthetic variables remain.

-}
expectNoSyntheticVars : Src.Module -> Expect.Expectation
expectNoSyntheticVars srcModule =
    TOMono.expectMonomorphization srcModule
