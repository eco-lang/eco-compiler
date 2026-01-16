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
import Expect


{-| TOPT_002: Verify decision trees have no nested patterns.
-}
expectDeciderNoNestedPatterns : Src.Module -> Expect.Expectation
expectDeciderNoNestedPatterns srcModule =
    -- TODO_TEST_LOGIC
    -- Compare source pattern matches to generated Decider trees:
    --   * Assert no nested patterns remain in the IR; all operate via flat bindings and destructor paths.
    --   * Walk all Path values in the Decider and verify none contain PCtorArg/PListCons etc.
    --     that would require nested matching.
    -- Oracle: Trees are structurally pattern-free.
    Debug.todo "Pattern matches compile to flat decision trees"


{-| TOPT_002: Verify decision trees are complete (exhaustive).
-}
expectDeciderComplete : Src.Module -> Expect.Expectation
expectDeciderComplete srcModule =
    -- TODO_TEST_LOGIC
    -- Compare source pattern matches to generated Decider trees:
    --   * Run an independent exhaustiveness checker on the decider trees.
    --   * Compare with earlier pattern check results.
    --   * Verify each leaf or FanOut completely covers remaining cases without overlap.
    -- Oracle: Trees are exhaustive and behavior-equivalent to original matches.
    Debug.todo "Pattern matches compile to exhaustive decision trees"
