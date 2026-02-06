module Compiler.Type.Constrain.Typed.NodeIds exposing
    ( NodeVarMap, NodeIdState
    , emptyNodeIdState
    , recordNodeVar, recordSyntheticExprVar
    )

{-| Unified node ID tracking for type constraint generation (Typed pathway).

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

@docs recordNodeVar, recordSyntheticExprVar

-}

import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO


{-| Mapping from node IDs to solver variables.

Each key is the ID of either a canonical expression or pattern,
and the value is the solver variable representing its type.

-}
type alias NodeVarMap =
    Dict Int Int IO.Variable


{-| State for tracking node ID to variable mappings during constraint generation.

The `syntheticExprIds` field tracks which expression IDs were recorded via
the Group B "generic" constraint path, where a synthetic placeholder variable
is allocated. This metadata enables tests to distinguish between legitimate
polymorphic TVars and unfilled placeholder holes.

-}
type alias NodeIdState =
    { mapping : NodeVarMap
    , syntheticExprIds : EverySet Int Int
    }


{-| Initial empty node ID state.
-}
emptyNodeIdState : NodeIdState
emptyNodeIdState =
    { mapping = Dict.empty
    , syntheticExprIds = EverySet.empty
    }


{-| Record a mapping from a node ID to its solver variable.

Negative IDs (used for placeholder nodes like synthesized patterns)
are skipped to avoid polluting the mapping.

-}
recordNodeVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordNodeVar id var state =
    if id >= 0 then
        { state | mapping = Dict.insert identity id var state.mapping }

    else
        -- Skip negative IDs (placeholders from makeExprPlaceholder, synthesized patterns)
        state


{-| Record a mapping from a synthetic Group B expression ID to its solver variable.

This is used for Group B expressions (lists, tuples, records, lambdas, etc.)
where the constraint generator allocates a synthetic placeholder variable.
The ID is also added to `syntheticExprIds` so tests can identify which
expression IDs had placeholder variables that PostSolve should fill.

-}
recordSyntheticExprVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordSyntheticExprVar id var state =
    if id >= 0 then
        { state
            | mapping = Dict.insert identity id var state.mapping
            , syntheticExprIds = EverySet.insert identity id state.syntheticExprIds
        }

    else
        -- Skip negative IDs
        state
