module Compiler.Type.Constrain.NodeIds exposing
    ( NodeVarMap
    , NodeIdState
    , emptyNodeIdState
    , recordNodeVar
    )

{-| Unified node ID tracking for type constraint generation.

This module provides a shared ID space for tracking solver variables
associated with canonical AST nodes (both expressions and patterns).

During constraint generation, each node is assigned a fresh type variable.
This module maintains the mapping from node IDs to those variables, enabling
the solver to later produce a mapping from node IDs to their inferred types.


# Types

@docs NodeVarMap, NodeIdState


# State

@docs emptyNodeIdState


# Recording

@docs recordNodeVar

-}

import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| Mapping from node IDs to solver variables.

Each key is the ID of either a canonical expression or pattern,
and the value is the solver variable representing its type.

-}
type alias NodeVarMap =
    Dict Int Int IO.Variable


{-| State for tracking node ID to variable mappings during constraint generation.
-}
type alias NodeIdState =
    { mapping : NodeVarMap
    }


{-| Initial empty node ID state.
-}
emptyNodeIdState : NodeIdState
emptyNodeIdState =
    { mapping = Dict.empty
    }


{-| Record a mapping from a node ID to its solver variable.

Negative IDs (used for placeholder nodes like synthesized patterns)
are skipped to avoid polluting the mapping.

-}
recordNodeVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordNodeVar id var state =
    if id >= 0 then
        { mapping = Dict.insert identity id var state.mapping }

    else
        -- Skip negative IDs (placeholders from makeExprPlaceholder, synthesized patterns)
        state
