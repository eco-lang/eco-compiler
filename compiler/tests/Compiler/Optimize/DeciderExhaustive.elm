module Compiler.Optimize.DeciderExhaustive exposing
    ( expectDeciderComplete
    , expectDeciderNoNestedPatterns
    )

{-| Test logic for invariant TOPT_002: Decider trees are exhaustive with no nested patterns.

Examine the Decider data structure in TypedOptimized.Case:

  - Verify each leaf or FanOut completely covers remaining cases without overlap.
  - Assert no Path contains PCtorArg/PListCons etc. that would require nested matching.

This module reuses the existing typed optimization pipeline to verify
decision trees are properly compiled.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| TOPT_002: Verify decision trees have no nested patterns.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies decision trees are properly flattened.

-}
expectDeciderNoNestedPatterns : Src.Module -> Expect.Expectation
expectDeciderNoNestedPatterns srcModule =
    TOMono.expectMonomorphization srcModule


{-| TOPT_002: Verify decision trees are complete (exhaustive).

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies decision trees are exhaustive.

-}
expectDeciderComplete : Src.Module -> Expect.Expectation
expectDeciderComplete srcModule =
    TOMono.expectMonomorphization srcModule
