module Compiler.Type.SolverSnapshot exposing
    ( SolverSnapshot, SolverState, TypeVar
    , resolveVariable
    )

{-| Snapshot of solver union-find state for post-inference queries.

This module captures the HM solver's union-find state (descriptors, point info,
weights) after constraint solving completes, enabling type queries outside the
IO monad.

@docs SolverSnapshot, SolverState, TypeVar
@docs resolveVariable

-}

import Array exposing (Array)
import Compiler.Data.Name as Name
import Data.Map as DMap
import System.TypeCheck.IO as IO


{-| A type variable from the solver's union-find.
-}
type alias TypeVar =
    IO.Variable


{-| Snapshot of the solver's mutable arrays at the time of capture.
-}
type alias SolverState =
    { descriptors : Array IO.Descriptor
    , pointInfo : Array IO.PointInfo
    , weights : Array Int
    }


{-| Complete snapshot: solver state + mapping from expression IDs to solver vars.
-}
type alias SolverSnapshot =
    { state : SolverState
    , nodeVars : Array (Maybe TypeVar)
    , annotationVars : DMap.Dict String Name.Name TypeVar
    }


resolveVariableHelp : Array IO.PointInfo -> TypeVar -> TypeVar
resolveVariableHelp pointInfo var =
    case var of
        IO.Pt idx ->
            case Array.get idx pointInfo of
                Just (IO.Link parent) ->
                    resolveVariableHelp pointInfo parent

                _ ->
                    -- Info or out of bounds: this is the root
                    var


{-| Resolve a variable to its union-find root using a SolverState snapshot.
-}
resolveVariable : SolverState -> TypeVar -> TypeVar
resolveVariable state var =
    resolveVariableHelp state.pointInfo var
