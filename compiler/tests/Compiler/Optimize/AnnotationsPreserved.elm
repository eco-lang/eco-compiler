module Compiler.Optimize.AnnotationsPreserved exposing
    ( expectAnnotationsPreserved
    )

{-| Test logic for invariant TOPT_003: Top-level annotations preserved in local graph.

For each top-level definition:

  - Compare its type scheme from type checking with the corresponding entry
    in Annotations inside LocalGraphData.
  - Assert every top-level name present in the module exists in the Annotations
    dict with identical scheme.

This module reuses the existing typed optimization pipeline to verify
annotations are preserved through optimization.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that all top-level annotations are preserved in the LocalGraphData.
-}
expectAnnotationsPreserved : Src.Module -> Expect.Expectation
expectAnnotationsPreserved srcModule =
    -- TODO_TEST_LOGIC
    -- For each top-level definition:
    --   * Compare its type scheme from type checking with the corresponding entry
    --     in Annotations inside LocalGraphData.
    --   * Assert every top-level name present in the module exists in the Annotations dict
    --     with identical scheme.
    -- Oracle: No missing or altered top-level schemes; later passes never need to re-run inference.
    Debug.todo "Top-level annotations preserved in local graph"
