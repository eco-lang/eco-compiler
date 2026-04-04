module Compiler.Type.SolverRoots exposing
    ( AllSchemeRoots
    , SchemeRootsForDef
    , normalizeAnnotationVars
    , normalizeNodeVars
    , normalizeAllSchemeRoots
    )

{-| Normalize solver variables to their union-find roots after solving.

After constraint solving completes, solver variables may still point through
chains of `Link` nodes in the union-find. This module provides functions to
resolve all variables to their canonical roots, ensuring that two variables
that the solver proved equivalent always map to the same root index.

@docs AllSchemeRoots, SchemeRootsForDef
@docs normalizeNodeVars, normalizeAnnotationVars, normalizeAllSchemeRoots

-}

import Array exposing (Array)
import Compiler.Data.Name as Name
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverState)
import Data.Map as DMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| Per-def mapping from forall binder names to their rooted solver variables.
-}
type alias SchemeRootsForDef =
    Dict Name.Name IO.Variable


{-| Mapping from definition names to their per-binder solver roots.
-}
type alias AllSchemeRoots =
    Dict Name.Name SchemeRootsForDef


{-| Resolve each node variable to its union-find root.
-}
normalizeNodeVars : SolverState -> Array (Maybe IO.Variable) -> Array (Maybe IO.Variable)
normalizeNodeVars state nodeVars =
    Array.map
        (\maybeVar ->
            case maybeVar of
                Just var ->
                    Just (SolverSnapshot.resolveVariable state var)

                Nothing ->
                    Nothing
        )
        nodeVars


{-| Resolve each annotation variable to its union-find root.
-}
normalizeAnnotationVars : SolverState -> DMap.Dict String Name.Name IO.Variable -> DMap.Dict String Name.Name IO.Variable
normalizeAnnotationVars state annotationVars =
    DMap.map (\_ var -> SolverSnapshot.resolveVariable state var) annotationVars


{-| Normalize all binder variables in AllSchemeRoots to their union-find roots.
-}
normalizeAllSchemeRoots : SolverState -> AllSchemeRoots -> AllSchemeRoots
normalizeAllSchemeRoots state allRoots =
    Dict.map
        (\_ schemeRoots ->
            Dict.map (\_ var -> SolverSnapshot.resolveVariable state var) schemeRoots
        )
        allRoots
