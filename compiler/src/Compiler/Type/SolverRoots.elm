module Compiler.Type.SolverRoots exposing
    ( AllSchemeRoots, SchemeRootsForDef
    , normalizeNodeVars, normalizeAnnotationVars, normalizeAllSchemeRoots
    , extractBinderRootsFromInferred
    , stampArrowRoots, stampArrowRootsInAnnotation
    )

{-| Code that runs after the type checker needs to know which type variables,
and which function arrows, the solver proved to be the same, but the solver's
union-find store does not outlive the type check. This module reads a snapshot
of that store, taken after solving, and records those answers in data that
does outlive it.

The store and its terms, _point_, _class_ and _root_, are described in
`Compiler.AST.TypeVars`, and the snapshot in `Compiler.Type.SolverSnapshot`. Two
variables the solver unified are in one class and resolve to one root, so
replacing every variable by its root gives each class one identity. A root is a
point of the store the snapshot was taken from, and means nothing apart from
it.

The module produces three things from a snapshot.

  - Variables replaced by their roots, by `normalizeNodeVars` and
    `normalizeAnnotationVars`.
  - _Scheme roots_: for one definition, each type variable name of its
    annotation mapped to a `Vars.RootedVar`, which is the variable's root
    together with the super-type read from that root's content.
    `normalizeAllSchemeRoots` builds them from variables already known by
    name, and `extractBinderRootsFromInferred` finds them by walking an
    annotation's type.
  - _Arrow root stamps_: `stampArrowRoots` writes into the slot of each
    function arrow the lockstep walk reaches the index of the root of the
    variable that arrow is matched with, as a `TypeIds.SolverRoot`. Arrows
    matched with variables of the same root get the same index. An arrow
    matched with a variable whose root holds an alias gets the alias's root,
    not that of the function type the alias expands to, so two arrows the
    solver unified can get different indices.
    `Compiler.AST.TypeIds.ArrowSlot` says what the index means, and that it
    means something only together with its module.

The last two rest on a _lockstep walk_, which descends a `Can.Type` and a
solver variable together, matching the type's children with the children of
the structure at the variable's root. It can follow only where the type has the
shape of the solver's structure. Where the two differ, for example because
the kinds of type differ, a record field is missing from the structure, a
child of the type has no counterpart among the structure's children, or the
root holds no structure, the walk goes no further down that branch: it records no scheme
roots there, and the stamp leaves that part of the type as it was, so its
arrows keep the slot they had. The one exception, a `Holey` alias whose
arguments do not match the solver's in number, is given at `stampArrowRoots`.
A `Filled` alias is walked through with the alias's own variable. Of a `Holey`
alias only the arguments are walked, against the arguments of the solver's
alias.

@docs AllSchemeRoots, SchemeRootsForDef
@docs normalizeNodeVars, normalizeAnnotationVars, normalizeAllSchemeRoots
@docs extractBinderRootsFromInferred
@docs stampArrowRoots, stampArrowRootsInAnnotation

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.Data.Name as Name
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverState)
import Dict exposing (Dict)


{-| The scheme roots of one definition: each type variable name of its
annotation, mapped to the root of the variable's class and that root's
super-type.

This is a name for a `Dict`, not a new type, so nothing checks that its keys are
the variables of any annotation or that its roots come from one store.

-}
type alias SchemeRootsForDef =
    Dict Name.Name Vars.RootedVar


{-| The scheme roots of a module's definitions, keyed by definition name.

This is a name for a `Dict`, not a new type.

-}
type alias AllSchemeRoots =
    Dict Name.Name SchemeRootsForDef


{-| Returns the super-type in the content of `rootVar`'s cell when that content
is a `FlexSuper` or a `RigidSuper`, and `Nothing` otherwise, which includes a
`rootVar` that is not a root of `state` or is outside it. The answer is read
from the solver, not from the name of any variable.
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


{-| Returns the root of `var`'s class together with the super-type recorded on
that root.
-}
rootedVarOf : SolverState -> Vars.Variable -> Vars.RootedVar
rootedVarOf state var =
    let
        rootVar =
            SolverSnapshot.resolveVariable state var
    in
    { var = rootVar, super = superOfRoot state rootVar }


{-| Replaces each variable in `nodeVars` by the root of its class, and keeps
each `Nothing`.
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


{-| Replaces each variable in `annotationVars` by the root of its class.
-}
normalizeAnnotationVars : SolverState -> Dict Name.Name Vars.Variable -> Dict Name.Name Vars.Variable
normalizeAnnotationVars state annotationVars =
    Dict.map (\_ var -> SolverSnapshot.resolveVariable state var) annotationVars


{-| Builds scheme roots from variables already known by name: for each
definition in `allRoots`, each type variable name's variable is replaced by
its root and that root's super-type.
-}
normalizeAllSchemeRoots : SolverState -> Dict Name.Name (Dict Name.Name Vars.Variable) -> AllSchemeRoots
normalizeAllSchemeRoots state allRoots =
    Dict.map
        (\_ schemeRoots ->
            Dict.map (\_ var -> rootedVarOf state var) schemeRoots
        )
        allRoots


{-| Returns the scheme roots of a definition, found by a lockstep walk of its
annotation's type against `annotVar`, the solver variable whose structure that
type is expected to share.

Each `TVar` the walk reaches is mapped to its root. The extension name of each
record type it reaches is mapped to the root of the extension point of the
solver's record structure. A variable the walk cannot reach is missing from the
result, and the result is empty when the annotation quantifies no variables.

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


{-| Adds to `acc` the scheme roots found by a lockstep walk of `canType`
against `var`.

A record is matched only against the fields of the `Record1` at the root, by
name, so a field the solver holds further along the record's extension chain
is not walked.

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
            -- The filled body is the type the alias's own variable stands for.
            walkTypeForBinders state innerType var acc

        Can.TAlias _ _ args (Can.Holey _) ->
            -- The holey body's variables are the alias's parameters, not the
            -- annotation's, so only the arguments are walked.
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


{-| Returns `canType` with the slot of each function arrow that a lockstep walk
against `var` reaches set to `TypeIds.SolverRoot` of the index of the arrow's
root.

An arrow's index is that of the root of the variable it is matched with, so
arrows matched with variables of the same root get the same index. Where that
root holds an alias, the `Fun1` is found by following the alias, but the index
is still the alias's root, so two arrows the solver unified can get different
indices. An arrow the walk does not reach keeps the slot it had. Within a
record, only the fields of the `Record1` at the root are matched, by name, so a
field the solver holds further along the record's extension chain is not
stamped. Of a `Holey` alias only the arguments are stamped, paired by position
with the arguments of the solver's alias; if the two lists differ in length,
the arguments beyond the shorter one are dropped from the result.

The index means something only together with the module whose solve produced
it, as `Compiler.AST.TypeIds.ArrowSlot` describes.

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
            -- The filled body is the type the alias's own variable stands for.
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


{-| Stamps each type in `types` as `stampArrowRoots` does, against the variable
at the same position in `vars`. Types beyond the end of `vars` are returned
unstamped.
-}
stampArrowRootsList : SolverState -> List (Can.Type Name.Name) -> List Vars.Variable -> List (Can.Type Name.Name)
stampArrowRootsList state types vars =
    case ( types, vars ) of
        ( t :: ts, v :: vs ) ->
            stampArrowRoots state t v :: stampArrowRootsList state ts vs

        _ ->
            types


{-| Returns the annotation with its type stamped as `stampArrowRoots` stamps a
type, against `annotVar`. The quantified names are unchanged.
-}
stampArrowRootsInAnnotation : SolverState -> Can.Annotation Name.Name -> Vars.Variable -> Can.Annotation Name.Name
stampArrowRootsInAnnotation state (Can.Forall freeVars tipe) annotVar =
    Can.Forall freeVars (stampArrowRoots state tipe annotVar)


{-| Adds to `acc` the scheme roots found by walking each type in `types`
against the variable at the same position in `vars`, as far as both lists go.
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


{-| Returns the content of the descriptor in the cell at `rootIdx`, or
`Nothing` when that cell is a `Chain` or `rootIdx` is outside `state`.
-}
lookupContent : SolverState -> Int -> Maybe Vars.Content
lookupContent state rootIdx =
    case Array.get rootIdx state.cells of
        Just (Vars.Root _ props) ->
            Just props.content

        _ ->
            Nothing


{-| Returns the structure held at `rootIdx`, following an alias to the root of
its expansion as many times as it takes. Returns `Nothing` when the content
reached is neither a structure nor an alias, or when a cell reached is a
`Chain` or outside `state`.
-}
lookupFlatType : SolverState -> Int -> Maybe Vars.FlatType
lookupFlatType state rootIdx =
    case lookupContent state rootIdx of
        Just (Vars.Structure flatType) ->
            Just flatType

        Just (Vars.Alias _ _ _ innerVar) ->
            let
                (Vars.Pt innerIdx) =
                    SolverSnapshot.resolveVariable state innerVar
            in
            lookupFlatType state innerIdx

        _ ->
            Nothing
