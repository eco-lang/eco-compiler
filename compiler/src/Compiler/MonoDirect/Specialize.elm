module Compiler.MonoDirect.Specialize exposing (specializeNode)

{-| Solver-directed expression specialization for MonoDirect.

Mirrors `Compiler.Monomorphize.Specialize` but with access to solver state
for enhanced type resolution. Currently delegates to the existing Specialize
module; future iterations will use solver variable queries where `tvar` is
available.

@docs specializeNode

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Specialize as BaseSpecialize
import Compiler.Monomorphize.State as BaseState
import Compiler.Type.SolverSnapshot exposing (SolverSnapshot)


{-| Specialize a TOpt.Node into a MonoNode.

Currently delegates to the existing Specialize module. Future iterations
will use solver variable queries for improved type resolution.

-}
specializeNode : SolverSnapshot -> Name -> TOpt.Node -> Mono.MonoType -> BaseState.MonoState -> ( Mono.MonoNode, BaseState.MonoState )
specializeNode _ name node monoType state =
    -- Delegate to existing specializer; snapshot unused in this iteration
    BaseSpecialize.specializeNode name node monoType state
