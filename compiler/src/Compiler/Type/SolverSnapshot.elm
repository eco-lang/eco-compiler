module Compiler.Type.SolverSnapshot exposing
    ( SolverState, TypeVar
    , resolveVariable
    )

{-| Snapshot of solver union-find state for post-inference queries.

This module captures the HM solver's union-find state (descriptors, point info,
weights) after constraint solving completes, enabling type queries outside the
IO monad.

@docs SolverState, TypeVar
@docs resolveVariable

-}

import Array exposing (Array)
import Compiler.Type.Vars as Vars


{-| A type variable from the solver's union-find.
-}
type alias TypeVar =
    Vars.Variable


{-| Snapshot of the solver's mutable arrays at the time of capture.
-}
type alias SolverState =
    { cells : Array Vars.PointCell
    }


resolveVariableHelp : Array Vars.PointCell -> TypeVar -> TypeVar
resolveVariableHelp cells var =
    case var of
        Vars.Pt idx ->
            case Array.get idx cells of
                Just (Vars.Chain parent) ->
                    resolveVariableHelp cells parent

                _ ->
                    -- Root or out of bounds: this is the root
                    var


{-| Resolve a variable to its union-find root using a SolverState snapshot.
-}
resolveVariable : SolverState -> TypeVar -> TypeVar
resolveVariable state var =
    resolveVariableHelp state.cells var
