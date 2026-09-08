module Compiler.Type.SolverRoots exposing
    ( AllSchemeRoots, SchemeRootsForDef
    , normalizeNodeVars, normalizeAnnotationVars, normalizeAllSchemeRoots
    , extractBinderRootsFromInferred
    , stampArrowRoots, stampArrowRootsInAnnotation
    )

{-| Normalize solver variables to their union-find roots after solving.

After constraint solving completes, solver variables may still point through
chains of `Link` nodes in the union-find. This module provides functions to
resolve all variables to their canonical roots, ensuring that two variables
that the solver proved equivalent always map to the same root index.

@docs AllSchemeRoots, SchemeRootsForDef
@docs normalizeNodeVars, normalizeAnnotationVars, normalizeAllSchemeRoots
@docs extractBinderRootsFromInferred
@docs stampArrowRoots, stampArrowRootsInAnnotation

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Name as Name
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverState)
import Compiler.Type.Vars as Vars
import Dict exposing (Dict)


{-| Per-def mapping from forall binder names to their rooted solver variables,
each carrying the super constraint read from its root descriptor.
-}
type alias SchemeRootsForDef =
    Dict Name.Name Vars.RootedVar


{-| Mapping from definition names to their per-binder solver roots.
-}
type alias AllSchemeRoots =
    Dict Name.Name SchemeRootsForDef


{-| Read the super constraint recorded on a solver variable's root descriptor.

Returns the `SuperType` when the root is a (flex or rigid) super variable, and
`Nothing` otherwise. This is solver truth about the ROOT — not a name lookup.

-}
superOfRoot : SolverState -> Vars.Variable -> Maybe Vars.SuperType
superOfRoot state rootVar =
    let
        (Vars.Pt rootIdx) =
            rootVar
    in
    case lookupContent state rootIdx of
        Just (Vars.FlexSuper s _) ->
            Just s

        Just (Vars.RigidSuper s _) ->
            Just s

        _ ->
            Nothing


{-| Resolve a variable to its root and pair it with the root's super.
-}
rootedVarOf : SolverState -> Vars.Variable -> Vars.RootedVar
rootedVarOf state var =
    let
        rootVar =
            SolverSnapshot.resolveVariable state var
    in
    { var = rootVar, super = superOfRoot state rootVar }


{-| Resolve each node variable to its union-find root.
-}
normalizeNodeVars : SolverState -> Array (Maybe Vars.Variable) -> Array (Maybe Vars.Variable)
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
normalizeAnnotationVars : SolverState -> Dict Name.Name Vars.Variable -> Dict Name.Name Vars.Variable
normalizeAnnotationVars state annotationVars =
    Dict.map (\_ var -> SolverSnapshot.resolveVariable state var) annotationVars


{-| Normalize all binder variables (raw solver vars) to their union-find roots,
attaching each root's super constraint.
-}
normalizeAllSchemeRoots : SolverState -> Dict Name.Name (Dict Name.Name Vars.Variable) -> AllSchemeRoots
normalizeAllSchemeRoots state allRoots =
    Dict.map
        (\_ schemeRoots ->
            Dict.map (\_ var -> rootedVarOf state var) schemeRoots
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
    -> Vars.Variable
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
    -> Vars.Variable
    -> SchemeRootsForDef
    -> SchemeRootsForDef
walkTypeForBinders state canType var acc =
    let
        rootVar =
            SolverSnapshot.resolveVariable state var

        (Vars.Pt rootIdx) =
            rootVar
    in
    case canType of
        Can.TVar name ->
            -- Leaf: record the binder name -> rooted var (with super) mapping
            Dict.insert name { var = rootVar, super = superOfRoot state rootVar } acc

        Can.TLambda _ argType resType ->
            case lookupFlatType state rootIdx of
                Just (Vars.Fun1 argVar resVar) ->
                    acc
                        |> walkTypeForBinders state argType argVar
                        |> walkTypeForBinders state resType resVar

                _ ->
                    acc

        Can.TType _ _ args ->
            case lookupFlatType state rootIdx of
                Just (Vars.App1 _ _ childVars) ->
                    walkTypeListForBinders state args childVars acc

                _ ->
                    acc

        Can.TRecord fields maybeExt ->
            case lookupFlatType state rootIdx of
                Just (Vars.Record1 fieldVars extVar) ->
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
                            Dict.insert extName (rootedVarOf state extVar) accAfterFields

                        Nothing ->
                            accAfterFields

                _ ->
                    acc

        Can.TTuple a b rest ->
            case lookupFlatType state rootIdx of
                Just (Vars.Tuple1 aVar bVar restVars) ->
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
                Just (Vars.Alias _ _ solverAliasArgs _) ->
                    List.foldl
                        (\( ( _, canArg ), ( _, solverVar ) ) a ->
                            walkTypeForBinders state canArg solverVar a
                        )
                        acc
                        (List.map2 Tuple.pair args solverAliasArgs)

                _ ->
                    acc


{-| **Phase 2b (`plans/lss-unknown-elimination.md` §4.9): give every arrow the
identity the type checker already computed for it.**

Walks a `Can.Type` in lockstep with its solver variable — the SAME descent
`walkTypeForBinders` uses, arm for arm — and rewrites each `Can.TLambda`'s
arrow slot to `TypeIds.SolverRoot rootIdx`, the arrow's own union-find root
index. Two arrows the solver UNIFIED therefore carry the same index, which is
exactly what per-occurrence ids (Phase 2a) cannot express: EXP-2a measured that
a def's annotation and its body node's type are structurally-equal DISTINCT
objects 97.5% of the time.

**The index is MODULE-LOCAL.** Each module's solve numbers its `Pt` from zero,
so it is only meaningful paired with the home module of the global that carries
it. `AssignMVarIds.ensureArrowIdForRoot` does that pairing, mirroring
`ensureMVarIdForRoot` — and that scoping is load-bearing, not hygiene: an
unscoped raw index would FALSELY union two unrelated lambda sets.

**Where the lockstep is lost, the subtree is left alone** (`NoArrow`), and
`AssignMVarIds` falls back to a fresh occurrence id. So 2b degrades to 2a
locally rather than failing — which is why the alias/mismatch arms below simply
return `canType`.

-}
stampArrowRoots : SolverState -> Can.Type Name.Name -> Vars.Variable -> Can.Type Name.Name
stampArrowRoots state canType var =
    let
        rootVar =
            SolverSnapshot.resolveVariable state var

        (Vars.Pt rootIdx) =
            rootVar
    in
    case canType of
        Can.TVar _ ->
            canType

        Can.TLambda _ argType resType ->
            case lookupFlatType state rootIdx of
                Just (Vars.Fun1 argVar resVar) ->
                    Can.TLambda (TypeIds.SolverRoot rootIdx)
                        (stampArrowRoots state argType argVar)
                        (stampArrowRoots state resType resVar)

                _ ->
                    canType

        Can.TType home name args ->
            case lookupFlatType state rootIdx of
                Just (Vars.App1 _ _ childVars) ->
                    Can.TType home name (stampArrowRootsList state args childVars)

                _ ->
                    canType

        Can.TRecord fields maybeExt ->
            case lookupFlatType state rootIdx of
                Just (Vars.Record1 fieldVars _) ->
                    Can.TRecord
                        (Dict.map
                            (\fieldName (Can.FieldType idx fieldType) ->
                                case Dict.get fieldName fieldVars of
                                    Just fieldVar ->
                                        Can.FieldType idx (stampArrowRoots state fieldType fieldVar)

                                    Nothing ->
                                        Can.FieldType idx fieldType
                            )
                            fields
                        )
                        maybeExt

                _ ->
                    canType

        Can.TTuple a b rest ->
            case lookupFlatType state rootIdx of
                Just (Vars.Tuple1 aVar bVar restVars) ->
                    Can.TTuple
                        (stampArrowRoots state a aVar)
                        (stampArrowRoots state b bVar)
                        (stampArrowRootsList state rest restVars)

                _ ->
                    canType

        Can.TUnit ->
            canType

        Can.TAlias home name args (Can.Filled innerType) ->
            -- Aliases are transparent; the solver var is the SAME var.
            Can.TAlias home name args (Can.Filled (stampArrowRoots state innerType var))

        Can.TAlias home name args (Can.Holey innerType) ->
            case lookupContent state rootIdx of
                Just (Vars.Alias _ _ solverAliasArgs _) ->
                    Can.TAlias home
                        name
                        (List.map2
                            (\( argName, canArg ) ( _, solverVar ) -> ( argName, stampArrowRoots state canArg solverVar ))
                            args
                            solverAliasArgs
                        )
                        (Can.Holey innerType)

                _ ->
                    canType


stampArrowRootsList : SolverState -> List (Can.Type Name.Name) -> List Vars.Variable -> List (Can.Type Name.Name)
stampArrowRootsList state types vars =
    case ( types, vars ) of
        ( t :: ts, v :: vs ) ->
            stampArrowRoots state t v :: stampArrowRootsList state ts vs

        _ ->
            -- Length mismatch: the lockstep is lost, leave the rest alone.
            types


{-| `stampArrowRoots` over a def's annotation.
-}
stampArrowRootsInAnnotation : SolverState -> Can.Annotation Name.Name -> Vars.Variable -> Can.Annotation Name.Name
stampArrowRootsInAnnotation state (Can.Forall freeVars tipe) annotVar =
    Can.Forall freeVars (stampArrowRoots state tipe annotVar)


{-| Walk parallel lists of Can.Types and solver variables.
-}
walkTypeListForBinders :
    SolverState
    -> List (Can.Type Name.Name)
    -> List Vars.Variable
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
lookupContent : SolverState -> Int -> Maybe Vars.Content
lookupContent state rootIdx =
    case Array.get rootIdx state.cells of
        Just (Vars.Root _ props) ->
            Just props.content

        _ ->
            -- Chain or out of bounds. Every caller feeds this a rootIdx that
            -- SolverSnapshot.resolveVariable just produced, so a Chain is
            -- unreachable; answering Nothing is strictly safer than the old
            -- code, which could not tell a root from a merged-away slot.
            Nothing


{-| Look up the FlatType for a solver variable, unwrapping through Alias content.
-}
lookupFlatType : SolverState -> Int -> Maybe Vars.FlatType
lookupFlatType state rootIdx =
    case lookupContent state rootIdx of
        Just (Vars.Structure flatType) ->
            Just flatType

        Just (Vars.Alias _ _ _ innerVar) ->
            -- Unwrap alias and look at the inner variable
            let
                (Vars.Pt innerIdx) =
                    SolverSnapshot.resolveVariable state innerVar
            in
            lookupFlatType state innerIdx

        _ ->
            Nothing
