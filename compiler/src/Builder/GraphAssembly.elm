module Builder.GraphAssembly exposing
    ( addOptGlobalGraph, addOptLocalGraph, addOptKernel
    , addTypedGlobalGraph, addTypedLocalGraph
    )

{-| A program is compiled one module at a time, but is linked as one graph;
this module joins the per-module and per-package graphs into that one graph.

A _local graph_ is what compiling one module yields: its definitions as nodes
keyed by global name, its record field counts and, on the typed path, its type
information. A _global graph_ is the same information for any number of modules
merged together. Both come in two kinds, the erased graphs of
`Compiler.AST.Optimized` and the typed graphs of `Compiler.AST.TypedOptimized`,
and each kind has its own functions here. A kernel module is added to an erased
global graph from its parsed chunks rather than from a local graph, by
`addOptKernel`.

Every merge is a left-biased union: where both sides hold an entry under the same
key, the entry from the first argument is kept and the other is dropped. That
holds for nodes, type information and field counts alike, so a field counted by
both sides keeps the first side's count rather than the sum. Adding a local
graph to a global graph therefore lets the local graph's entries win. A local
graph's `main` is not carried into the global graph.


# Optimized Graph Operations

@docs addOptGlobalGraph, addOptLocalGraph, addOptKernel


# TypedOptimized Graph Operations

@docs addTypedGlobalGraph, addTypedLocalGraph

-}

import Compiler.AST.Optimized as Opt
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Kernel as K
import Compiler.Elm.ModuleName as ModuleName
import Data.Map
import Data.Set as EverySet
import Dict



-- ====== OPTIMIZED GRAPH OPERATIONS ======


{-| Returns one global graph holding the nodes and field counts of both,
keeping the first graph's entry where both have one.
-}
addOptGlobalGraph : Opt.GlobalGraph -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptGlobalGraph (Opt.GlobalGraph nodes1 fields1) (Opt.GlobalGraph nodes2 fields2) =
    Opt.GlobalGraph
        (Data.Map.union nodes1 nodes2)
        (Dict.union fields1 fields2)


{-| Returns the global graph with the local graph's nodes and field counts
added, the local graph's entries replacing any under the same key. The local
graph's `main` is dropped.
-}
addOptLocalGraph : Opt.LocalGraph -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptLocalGraph (Opt.LocalGraph _ nodes1 fields1) (Opt.GlobalGraph nodes2 fields2) =
    Opt.GlobalGraph
        (Data.Map.union nodes1 nodes2)
        (Dict.union fields1 fields2)


{-| Returns the global graph with a node added for the kernel module named
`moduleName` (such as `Elm.Kernel.File` or `Eco.Kernel.File`), built from its
parsed chunks. `Name.getKernel` crashes on a name that is neither kind of
kernel module name.

The node is keyed as `Opt.toKernelGlobal` describes, so `Elm.Kernel.File` and
`Eco.Kernel.File` stay two nodes. It replaces any node already under that key.
Its dependencies are the Elm values and kernel modules the chunks refer to.
The kernel's field counts, from `K.countFields`, are added to the graph's,
replacing the graph's count for a field both hold.

-}
addOptKernel : ModuleName.Raw -> List K.Chunk -> Opt.GlobalGraph -> Opt.GlobalGraph
addOptKernel moduleName chunks (Opt.GlobalGraph nodes fields) =
    let
        ( kernelPrefix, home ) =
            Name.getKernel moduleName

        global : Opt.Global
        global =
            Opt.toKernelGlobal kernelPrefix home

        node : Opt.Node
        node =
            Opt.Kernel chunks (List.foldr addKernelDep EverySet.empty chunks)
    in
    Opt.GlobalGraph
        (Data.Map.insert Opt.toComparableGlobal global node nodes)
        (Dict.union (K.countFields chunks) fields)


{-| Returns `deps` with the global that `chunk` refers to added: the Elm value
of an `ElmVar`, or the kernel module of a `JsVar`. Any other chunk refers to no
global and leaves `deps` unchanged.
-}
addKernelDep : K.Chunk -> EverySet.EverySet String Opt.Global -> EverySet.EverySet String Opt.Global
addKernelDep chunk deps =
    case chunk of
        K.JS _ ->
            deps

        K.ElmVar home name ->
            EverySet.insert Opt.toComparableGlobal (Opt.Global home name) deps

        K.JsVar kernelPrefix home _ ->
            EverySet.insert Opt.toComparableGlobal (Opt.toKernelGlobal kernelPrefix home) deps

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



-- ====== TYPED OPTIMIZED GRAPH OPERATIONS ======


{-| Returns one typed global graph holding the nodes, field counts, type
schemes, scheme roots and varSupers (see `TOpt.GlobalGraph`) of both, keeping
the first graph's entry where both have one.
-}
addTypedGlobalGraph : TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
addTypedGlobalGraph (TOpt.GlobalGraph nodes1 fields1 ann1 roots1 varSupers1) (TOpt.GlobalGraph nodes2 fields2 ann2 roots2 varSupers2) =
    TOpt.GlobalGraph
        (Data.Map.union nodes1 nodes2)
        (Dict.union fields1 fields2)
        (Data.Map.union ann1 ann2)
        (Data.Map.union roots1 roots2)
        (Dict.union varSupers1 varSupers2)


{-| Returns the typed global graph with the local graph's nodes, field counts,
type schemes, scheme roots and varSupers added, the local graph's entries
replacing any under the same key. The local graph's `main` is dropped.

A local graph keys its type schemes and scheme roots by bare name, and a global
graph keys them by global. Each is re-keyed by going through the local graph's
nodes and taking, for each node, the entry under that node's name. An entry
whose name has no node is therefore not carried over.

-}
addTypedLocalGraph : TOpt.LocalGraph Name -> TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
addTypedLocalGraph (TOpt.LocalGraph data) (TOpt.GlobalGraph nodes2 fields2 ann2 roots2 varSupers2) =
    let
        globalAnnotations =
            Data.Map.foldl
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

        globalSchemeRoots =
            Data.Map.foldl
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
        (Dict.union data.varSupers varSupers2)
