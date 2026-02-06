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
import Data.Map as Dict
import Data.Set as EverySet
import System.TypeCheck.IO as IO



-- ====== OPTIMIZED GRAPH OPERATIONS ======


{-| Merge two global graphs by combining their nodes and fields.
-}
addOptGlobalGraph : Opt.GlobalGraph -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptGlobalGraph (Opt.GlobalGraph nodes1 fields1) (Opt.GlobalGraph nodes2 fields2) =
    Opt.GlobalGraph
        (Dict.union nodes1 nodes2)
        (Dict.union fields1 fields2)


{-| Add a local graph to a global graph by merging nodes and fields.
-}
addOptLocalGraph : Opt.LocalGraph -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptLocalGraph (Opt.LocalGraph _ nodes1 fields1) (Opt.GlobalGraph nodes2 fields2) =
    Opt.GlobalGraph
        (Dict.union nodes1 nodes2)
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
        (Dict.insert Opt.toComparableGlobal global node nodes)
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
addTypedGlobalGraph : TOpt.GlobalGraph -> TOpt.GlobalGraph -> TOpt.GlobalGraph
addTypedGlobalGraph (TOpt.GlobalGraph nodes1 fields1 ann1) (TOpt.GlobalGraph nodes2 fields2 ann2) =
    TOpt.GlobalGraph
        (Dict.union nodes1 nodes2)
        (Dict.union fields1 fields2)
        (Dict.union ann1 ann2)


{-| Add a typed local graph's definitions to a typed global graph.
-}
addTypedLocalGraph : TOpt.LocalGraph -> TOpt.GlobalGraph -> TOpt.GlobalGraph
addTypedLocalGraph (TOpt.LocalGraph data) (TOpt.GlobalGraph nodes2 fields2 ann2) =
    TOpt.GlobalGraph
        (Dict.union data.nodes nodes2)
        (Dict.union data.fields fields2)
        (Dict.union data.annotations ann2)
