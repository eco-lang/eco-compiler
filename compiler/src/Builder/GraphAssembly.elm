module Builder.GraphAssembly exposing
    ( addOptGlobalGraph, addOptLocalGraph, addOptKernel
    , addTypedGlobalGraph, addTypedLocalGraph
    )

{-| Graph assembly utilities for merging dependency graphs during build.

This module provides functions to combine and merge the various graph types
used by the compiler during the build phase. These are "linking" operations
that assemble multiple compiled modules into a single program graph.


# Optimized Graph Operations

@docs addOptGlobalGraph, addOptLocalGraph, addOptKernel


# TypedOptimized Graph Operations

@docs addTypedGlobalGraph, addTypedLocalGraph

-}

import Compiler.AST.Optimized as Opt
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Kernel as K
import Compiler.Elm.Package as Pkg
import Data.Map
import Data.Set as EverySet
import Dict
import System.TypeCheck.IO as IO



-- ====== OPTIMIZED GRAPH OPERATIONS ======


{-| Merge two global graphs by combining their nodes and fields.
-}
addOptGlobalGraph : Opt.GlobalGraph -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptGlobalGraph (Opt.GlobalGraph nodes1 fields1) (Opt.GlobalGraph nodes2 fields2) =
    Opt.GlobalGraph
        (Data.Map.union nodes1 nodes2)
        (Dict.union fields1 fields2)


{-| Add a local graph to a global graph by merging nodes and fields.
-}
addOptLocalGraph : Opt.LocalGraph -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptLocalGraph (Opt.LocalGraph _ nodes1 fields1) (Opt.GlobalGraph nodes2 fields2) =
    Opt.GlobalGraph
        (Data.Map.union nodes1 nodes2)
        (Dict.union fields1 fields2)


{-| Add a kernel definition to the global graph.
-}
addOptKernel : Name -> List K.Chunk -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptKernel shortName chunks (Opt.GlobalGraph nodes fields) =
    let
        global : Opt.Global
        global =
            toKernelGlobal shortName

        node : Opt.Node
        node =
            Opt.Kernel chunks (List.foldr addKernelDep EverySet.empty chunks)
    in
    Opt.GlobalGraph
        (Data.Map.insert Opt.toComparableGlobal global node nodes)
        (Dict.union (K.countFields chunks) fields)


addKernelDep : K.Chunk -> EverySet.EverySet (List String) Opt.Global -> EverySet.EverySet (List String) Opt.Global
addKernelDep chunk deps =
    case chunk of
        K.JS _ ->
            deps

        K.ElmVar home name ->
            EverySet.insert Opt.toComparableGlobal (Opt.Global home name) deps

        K.JsVar shortName _ ->
            EverySet.insert Opt.toComparableGlobal (toKernelGlobal shortName) deps

        K.ElmField _ ->
            deps

        K.JsField _ ->
            deps

        K.JsEnum _ ->
            deps

        K.Debug ->
            deps

        K.Prod ->
            deps


toKernelGlobal : Name.Name -> Opt.Global
toKernelGlobal shortName =
    Opt.Global (IO.Canonical Pkg.kernel shortName) Name.dollar



-- ====== TYPED OPTIMIZED GRAPH OPERATIONS ======


{-| Merge two typed global graphs by unioning their nodes, fields, and annotations.
-}
addTypedGlobalGraph : TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
addTypedGlobalGraph (TOpt.GlobalGraph nodes1 fields1 ann1 roots1) (TOpt.GlobalGraph nodes2 fields2 ann2 roots2) =
    TOpt.GlobalGraph
        (Data.Map.union nodes1 nodes2)
        (Dict.union fields1 fields2)
        (Data.Map.union ann1 ann2)
        (Data.Map.union roots1 roots2)


{-| Add a typed local graph's definitions to a typed global graph.

Annotations and scheme roots in the LocalGraph are keyed by bare Name (per-module).
We re-key them by Global using the nodes map to find the full identity for each name.

-}
addTypedLocalGraph : TOpt.LocalGraph Name -> TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
addTypedLocalGraph (TOpt.LocalGraph data) (TOpt.GlobalGraph nodes2 fields2 ann2 roots2) =
    let
        -- Re-key annotations from bare Name to Global by iterating through nodes
        globalAnnotations =
            Data.Map.foldl TOpt.compareGlobal
                (\global _ acc ->
                    let
                        name =
                            case global of
                                TOpt.Global _ n ->
                                    n
                    in
                    case Dict.get name data.annotations of
                        Just ann ->
                            Data.Map.insert TOpt.toComparableGlobal global ann acc

                        Nothing ->
                            acc
                )
                Data.Map.empty
                data.nodes

        -- Re-key scheme roots from bare Name to Global similarly
        globalSchemeRoots =
            Data.Map.foldl TOpt.compareGlobal
                (\global _ acc ->
                    let
                        name =
                            case global of
                                TOpt.Global _ n ->
                                    n
                    in
                    case Dict.get name data.schemeRoots of
                        Just roots ->
                            Data.Map.insert TOpt.toComparableGlobal global roots acc

                        Nothing ->
                            acc
                )
                Data.Map.empty
                data.nodes
    in
    TOpt.GlobalGraph
        (Data.Map.union data.nodes nodes2)
        (Dict.union data.fields fields2)
        (Data.Map.union globalAnnotations ann2)
        (Data.Map.union globalSchemeRoots roots2)
