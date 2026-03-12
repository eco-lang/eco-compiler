module Compiler.MonoDirect.Monomorphize exposing (monomorphizeDirect)

{-| Solver-directed monomorphization entry point.

This module provides `monomorphizeDirect`, which mirrors the existing
`Monomorphize.monomorphize` but carries a `SolverSnapshot` for future
solver-driven type resolution.

Currently delegates to the existing monomorphizer. Future iterations will
use `MonoDirect.Specialize` with solver variable queries.

This is a test-only module — not wired into the production pipeline.

@docs monomorphizeDirect

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Monomorphize as BaseMono
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverSnapshot)


{-| Monomorphize a global graph using solver-directed type resolution.

Takes the same inputs as `Monomorphize.monomorphize` plus a `SolverSnapshot`.
Currently delegates to the existing monomorphizer; the snapshot is carried
for future use in solver-driven specialization.

-}
monomorphizeDirect :
    Name
    -> TypeEnv.GlobalTypeEnv
    -> SolverSnapshot
    -> TOpt.GlobalGraph
    -> Result String Mono.MonoGraph
monomorphizeDirect entryPointName globalTypeEnv _ globalGraph =
    -- Delegate to existing monomorphizer; snapshot unused in this iteration
    BaseMono.monomorphize entryPointName globalTypeEnv globalGraph
