module Compiler.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , expectMonoGraphComplete
    , expectMonoGraphClosed
    , expectSpecRegistryComplete
    )

{-| Test logic for invariants:

  - MONO_004: All functions are callable MonoNodes
  - MONO_010: MonoGraph is type complete
  - MONO_011: MonoGraph is closed and hygienic
  - MONO_005: Specialization registry is complete and consistent

This module reuses the existing typed optimization pipeline to verify
MonoGraph integrity. Successful monomorphization implies all these
invariants are satisfied.

-}

import Compiler.AST.Source as Src
import Expect


{-| MONO_004: Verify that all function-typed nodes are callable.
-}
expectCallableMonoNodes : Src.Module -> Expect.Expectation
expectCallableMonoNodes srcModule =
    -- TODO_TEST_LOGIC
    -- For each MonoNode whose MonoType is a function:
    --   * Assert the node variant is either MonoTailFunc or MonoDefine whose expression is MonoClosure.
    --   * Assert there are no function-typed nodes lacking an implementation or with incompatible constructors.
    -- Oracle: Every function type corresponds to an actually callable implementation; no orphan function types.
    Debug.todo "All functions are callable MonoNodes"


{-| MONO_010: Verify MonoGraph is type complete.
-}
expectMonoGraphComplete : Src.Module -> Expect.Expectation
expectMonoGraphComplete srcModule =
    -- TODO_TEST_LOGIC
    -- Traverse the entire MonoGraph:
    --   * Assert every referenced MonoType is present and fully elaborated (no dangling references).
    --   * Ensure ctorLayouts for custom types include all constructors and their types.
    -- Oracle: There are no missing type definitions; MonoGraph fully describes program types and constructors.
    Debug.todo "MonoGraph is type complete"


{-| MONO_011: Verify MonoGraph is closed and hygienic.
-}
expectMonoGraphClosed : Src.Module -> Expect.Expectation
expectMonoGraphClosed srcModule =
    -- TODO_TEST_LOGIC
    -- For each local/global variable and specialization:
    --   * Check every MonoVarLocal resolves to a binder in scope.
    --   * Check every MonoVarGlobal and SpecId refer to existing MonoNodes.
    --   * Detect unreachable SpecIds and ensure they're either optimized away or flagged.
    -- Oracle: No dangling references, no undefined globals, no unreachable specs in the registry.
    Debug.todo "MonoGraph is closed and hygienic"


{-| MONO_005: Verify specialization registry is complete.
-}
expectSpecRegistryComplete : Src.Module -> Expect.Expectation
expectSpecRegistryComplete srcModule =
    -- TODO_TEST_LOGIC
    -- For each entry in SpecializationRegistry (keyed by Global + MonoType + LambdaId):
    --   * Assert it maps to a unique SpecId.
    --   * Assert each SpecId used in MonoVarGlobal refers to an existing MonoNode.
    --   * Assert there are no registry entries that are never referenced.
    -- Oracle: 1-1 mapping between specializations and nodes; no missing or orphan specs.
    Debug.todo "Specialization registry is complete and consistent"
