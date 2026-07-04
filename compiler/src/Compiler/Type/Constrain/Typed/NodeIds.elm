module Compiler.Type.Constrain.Typed.NodeIds exposing
    ( NodeVarMap, NodeIdState
    , emptyNodeIdState, erasedNodeIdState
    , recordNodeVar, recordSyntheticExprVar
    , SchemeBinderVars, recordSchemeBinders
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


# Scheme Binder Recording

@docs SchemeBinderVars, recordSchemeBinders

-}

import Array exposing (Array)
import Compiler.Data.Name as Name
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| Mapping from definition names to their forall binder → solver variable mappings.
-}
type alias SchemeBinderVars =
    Dict Name.Name (Dict Name.Name IO.Variable)


{-| Mapping from node IDs to solver variables.

Each key is the ID of either a canonical expression or pattern,
and the value is the solver variable representing its type.

-}
type alias NodeVarMap =
    Array (Maybe IO.Variable)


{-| State for tracking node ID to variable mappings during constraint generation.

The `syntheticExprIds` field tracks which expression IDs were recorded via
the remaining Group B "generic" constraint path (Str, Chr, Float, Unit, Shader),
where a synthetic placeholder variable is allocated. This metadata enables tests
to distinguish between legitimate polymorphic TVars and unfilled placeholder holes.

-}
type alias NodeIdState =
    { mapping : NodeVarMap
    , syntheticExprIds : EverySet Int Int
    , schemeBinderVars : Dict Name.Name (Dict Name.Name IO.Variable)
    , recording : Bool
    }


{-| Initial node ID state with recording ENABLED (the Typed pathway).
-}
emptyNodeIdState : NodeIdState
emptyNodeIdState =
    { mapping = Array.empty
    , syntheticExprIds = EverySet.empty
    , schemeBinderVars = Dict.empty
    , recording = True
    }


{-| Node ID state with recording DISABLED (the Erased pathway).

The single generator runs with this state to produce the erased constraints:
`recordNodeVar`/`recordSyntheticExprVar`/`recordSchemeBinders` all become no-ops
(so no id→var table is built), and the Group B synthetic-placeholder wrapper is
skipped in `Constrain.Typed.Expression`, so the constraints match the plain
type-check pathway without paying for node tracking on the JS backend.

-}
erasedNodeIdState : NodeIdState
erasedNodeIdState =
    { emptyNodeIdState | recording = False }


{-| Record a mapping from a node ID to its solver variable.

Negative IDs (used for placeholder nodes like synthesized patterns)
are skipped to avoid polluting the mapping.

-}
recordNodeVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordNodeVar id var state =
    if state.recording && id >= 0 then
        { state | mapping = arraySetGrowing id (Just var) state.mapping }

    else
        -- Not recording (erased pathway), or a negative ID (placeholders from
        -- makeExprPlaceholder / synthesized patterns): skip.
        state


{-| Record a mapping from a synthetic Group B expression ID to its solver variable.

This is used for remaining Group B expressions (Str, Chr, Float, Unit, Shader)
where the constraint generator allocates a synthetic placeholder variable.
The ID is also added to `syntheticExprIds` so tests can identify which
expression IDs had placeholder variables that PostSolve should fill.

-}
recordSyntheticExprVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordSyntheticExprVar id var state =
    if state.recording && id >= 0 then
        { state
            | mapping = arraySetGrowing id (Just var) state.mapping
            , syntheticExprIds = EverySet.insert identity id state.syntheticExprIds
        }

    else
        -- Not recording (erased pathway) or a negative ID: skip.
        state


{-| Record the forall binder → solver variable mapping for a definition.
-}
recordSchemeBinders : Name.Name -> Dict.Dict Name.Name IO.Variable -> NodeIdState -> NodeIdState
recordSchemeBinders defName binders state =
    if state.recording then
        { state | schemeBinderVars = Dict.insert defName binders state.schemeBinderVars }

    else
        state


arraySetGrowing : Int -> Maybe a -> Array (Maybe a) -> Array (Maybe a)
arraySetGrowing idx val arr =
    if idx < Array.length arr then
        Array.set idx val arr

    else
        Array.append arr (Array.repeat (idx - Array.length arr) Nothing)
            |> Array.push val
