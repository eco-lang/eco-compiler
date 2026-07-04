module Compiler.Type.SolverRoots exposing
    ( AllSchemeRoots, SchemeRootsForDef
    , normalizeNodeVars, normalizeAnnotationVars, normalizeAllSchemeRoots
    , extractBinderRootsFromInferred
    )

{-| Normalize solver variables to their union-find roots after solving.

After constraint solving completes, solver variables may still point through
chains of `Link` nodes in the union-find. This module provides functions to
resolve all variables to their canonical roots, ensuring that two variables
that the solver proved equivalent always map to the same root index.

@docs AllSchemeRoots, SchemeRootsForDef
@docs normalizeNodeVars, normalizeAnnotationVars, normalizeAllSchemeRoots
@docs extractBinderRootsFromInferred

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverState)
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
normalizeAnnotationVars : SolverState -> Dict Name.Name IO.Variable -> Dict Name.Name IO.Variable
normalizeAnnotationVars state annotationVars =
    Dict.map (\_ var -> SolverSnapshot.resolveVariable state var) annotationVars


{-| Normalize all binder variables in AllSchemeRoots to their union-find roots.
-}
normalizeAllSchemeRoots : SolverState -> AllSchemeRoots -> AllSchemeRoots
normalizeAllSchemeRoots state allRoots =
    Dict.map
        (\_ schemeRoots ->
            Dict.map (\_ var -> SolverSnapshot.resolveVariable state var) schemeRoots
        )
        allRoots


{-| Extract binder-to-root mappings for an unannotated definition by walking
the solver's type descriptor tree in lockstep with the inferred annotation type.

For each `TVar name` in the annotation, finds the corresponding solver variable
in the descriptor tree and resolves it to its union-find root.

-}
extractBinderRootsFromInferred :
    SolverState
    -> Can.Annotation Name.Name
    -> IO.Variable
    -> SchemeRootsForDef
extractBinderRootsFromInferred state (Can.Forall freeVars tipe) annotVar =
    if Dict.isEmpty freeVars then
        Dict.empty

    else
        let
            rootVar =
                SolverSnapshot.resolveVariable state annotVar
        in
        walkTypeForBinders state tipe rootVar Dict.empty


{-| Walk a Can.Type and a solver variable in parallel, recording TVar->root mappings.
-}
walkTypeForBinders :
    SolverState
    -> Can.Type Name.Name
    -> IO.Variable
    -> SchemeRootsForDef
    -> SchemeRootsForDef
walkTypeForBinders state canType var acc =
    let
        rootVar =
            SolverSnapshot.resolveVariable state var

        (IO.Pt rootIdx) =
            rootVar
    in
    case canType of
        Can.TVar name ->
            -- Leaf: record the binder name -> root variable mapping
            Dict.insert name rootVar acc

        Can.TLambda argType resType ->
            case lookupFlatType state rootIdx of
                Just (IO.Fun1 argVar resVar) ->
                    acc
                        |> walkTypeForBinders state argType argVar
                        |> walkTypeForBinders state resType resVar

                _ ->
                    acc

        Can.TType _ _ args ->
            case lookupFlatType state rootIdx of
                Just (IO.App1 _ _ childVars) ->
                    walkTypeListForBinders state args childVars acc

                _ ->
                    acc

        Can.TRecord fields maybeExt ->
            case lookupFlatType state rootIdx of
                Just (IO.Record1 fieldVars extVar) ->
                    let
                        accAfterFields =
                            Dict.foldl
                                (\fieldName (Can.FieldType _ fieldType) a ->
                                    case Dict.get fieldName fieldVars of
                                        Just fieldVar ->
                                            walkTypeForBinders state fieldType fieldVar a

                                        Nothing ->
                                            a
                                )
                                acc
                                fields
                    in
                    case maybeExt of
                        Just extName ->
                            Dict.insert extName (SolverSnapshot.resolveVariable state extVar) accAfterFields

                        Nothing ->
                            accAfterFields

                _ ->
                    acc

        Can.TTuple a b rest ->
            case lookupFlatType state rootIdx of
                Just (IO.Tuple1 aVar bVar restVars) ->
                    acc
                        |> walkTypeForBinders state a aVar
                        |> walkTypeForBinders state b bVar
                        |> (\acc2 -> walkTypeListForBinders state rest restVars acc2)

                _ ->
                    acc

        Can.TUnit ->
            acc

        Can.TAlias _ _ _ (Can.Filled innerType) ->
            -- Aliases are transparent; walk through the filled type
            walkTypeForBinders state innerType var acc

        Can.TAlias _ _ args (Can.Holey _) ->
            -- For holey aliases, walk the alias args against the solver's alias args
            case lookupContent state rootIdx of
                Just (IO.Alias _ _ solverAliasArgs _) ->
                    List.foldl
                        (\( ( _, canArg ), ( _, solverVar ) ) a ->
                            walkTypeForBinders state canArg solverVar a
                        )
                        acc
                        (List.map2 Tuple.pair args solverAliasArgs)

                _ ->
                    acc


{-| Walk parallel lists of Can.Types and solver variables.
-}
walkTypeListForBinders :
    SolverState
    -> List (Can.Type Name.Name)
    -> List IO.Variable
    -> SchemeRootsForDef
    -> SchemeRootsForDef
walkTypeListForBinders state types vars acc =
    case ( types, vars ) of
        ( t :: ts, v :: vs ) ->
            walkTypeListForBinders state ts vs (walkTypeForBinders state t v acc)

        _ ->
            acc


{-| Look up the Content of a solver variable by its root index.
-}
lookupContent : SolverState -> Int -> Maybe IO.Content
lookupContent state rootIdx =
    case Array.get rootIdx state.descriptors of
        Just props ->
            Just props.content

        Nothing ->
            Nothing


{-| Look up the FlatType for a solver variable, unwrapping through Alias content.
-}
lookupFlatType : SolverState -> Int -> Maybe IO.FlatType
lookupFlatType state rootIdx =
    case lookupContent state rootIdx of
        Just (IO.Structure flatType) ->
            Just flatType

        Just (IO.Alias _ _ _ innerVar) ->
            -- Unwrap alias and look at the inner variable
            let
                (IO.Pt innerIdx) =
                    SolverSnapshot.resolveVariable state innerVar
            in
            lookupFlatType state innerIdx

        _ ->
            Nothing
