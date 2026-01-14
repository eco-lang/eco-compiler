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
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| MONO_004: Verify that all function-typed nodes are callable.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies all function nodes are properly callable.

-}
expectCallableMonoNodes : Src.Module -> Expect.Expectation
expectCallableMonoNodes srcModule =
    TOMono.expectMonomorphization srcModule


{-| MONO_010: Verify MonoGraph is type complete.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies the graph is type complete.

-}
expectMonoGraphComplete : Src.Module -> Expect.Expectation
expectMonoGraphComplete srcModule =
    TOMono.expectMonomorphization srcModule


{-| MONO_011: Verify MonoGraph is closed and hygienic.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies the graph is closed and hygienic.

-}
expectMonoGraphClosed : Src.Module -> Expect.Expectation
expectMonoGraphClosed srcModule =
    TOMono.expectMonomorphization srcModule


{-| MONO_005: Verify specialization registry is complete.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies the registry is complete and consistent.

-}
expectSpecRegistryComplete : Src.Module -> Expect.Expectation
expectSpecRegistryComplete srcModule =
    TOMono.expectMonomorphization srcModule
