module Compiler.Graph exposing (IntGraph, SCC(..), stronglyConnComp, stronglyConnCompInt)

{-| Groups the nodes of a dependency graph into mutually recursive groups and
orders the groups so that each comes after everything it depends on.

The graph is directed, and an edge runs from a node to a node it depends on. A
_strongly connected component_ (SCC) is a largest set of nodes each of which
can reach every other by following edges: a group of definitions that refer to
one another, directly or through each other. Collapsing each component to one
node leaves a graph with no cycles, and the components are returned in an order
of that graph in which every component comes after every component it has an
edge to. Processing the list from the front therefore meets each group only
after the groups it depends on.

A component is _cyclic_ when it has more than one node, or when its one node
has an edge to itself; otherwise it is _acyclic_. `SCC` keeps the two apart.

There are two entry points. `stronglyConnComp` takes nodes named by keys, each
with the keys it depends on, and numbers them itself. `stronglyConnCompInt`
takes an `IntGraph`, whose vertices are already numbered.

Both use Kosaraju's algorithm. A depth-first search of the graph with every
edge reversed gives the vertices in reverse post-order, the order in which the
search finished with them, latest first. A second search, this time along the
edges as given, starts from each unvisited vertex in that order, and each
search collects exactly one component. Both searches keep their own stack of
pending vertices and are tail recursive, so a deep graph does not exhaust the
call stack.

@docs IntGraph, SCC, stronglyConnComp, stronglyConnCompInt

-}

import Array exposing (Array)
import Bitwise
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Dict as CoreDict


{-| One strongly connected component of a graph.

`AcyclicSCC` is a single node with no edge to itself.

`CyclicSCC` holds the nodes of a component that has a cycle. It may hold just
one node, when that node has an edge to itself. Its nodes are in the reverse of
the order in which the second search reached them, not in input order.

-}
type SCC vertex
    = AcyclicSCC vertex
    | CyclicSCC (List vertex)


{-| A directed graph whose vertices are the integers from 0 to `size - 1`,
given in the three forms that `stronglyConnCompInt` reads.

`fwd` holds, at each vertex, the vertices it has an edge to. `trans` is the
same graph with every edge reversed, and `selfLoops` is the set of vertices
with an edge to themselves. Both must agree with `fwd`, and every vertex named
in `fwd` or `trans` must be below `size`; nothing checks either. A `trans` that
is not `fwd` reversed can give wrong components in a wrong order, and
`selfLoops` alone decides whether a single vertex is `CyclicSCC` or
`AcyclicSCC`. A vertex with no entry in `fwd` or `trans` is read as having no
edges.

-}
type alias IntGraph =
    { fwd : Array (List Int)
    , trans : Array (List Int)
    , selfLoops : BitSet
    , size : Int
    }


{-| Returns the strongly connected components of an `IntGraph`, each after
every component it has an edge to.

The result is correct only when the graph meets the contract stated on
`IntGraph`.

-}
stronglyConnCompInt : IntGraph -> List (SCC Int)
stronglyConnCompInt { fwd, trans, selfLoops, size } =
    let
        rpo =
            reversePostOrder trans size

        ( _, sccs ) =
            List.foldl
                (\v ( visited, acc ) ->
                    if BitSet.member v visited then
                        ( visited, acc )

                    else
                        let
                            ( newVisited, component ) =
                                collectComponent fwd v visited
                        in
                        case component of
                            [ single ] ->
                                if BitSet.member single selfLoops then
                                    ( newVisited, CyclicSCC [ single ] :: acc )

                                else
                                    ( newVisited, AcyclicSCC single :: acc )

                            _ ->
                                ( newVisited, CyclicSCC component :: acc )
                )
                ( BitSet.emptyWithSize size, [] )
                rpo
    in
    List.reverse sccs


{-| Returns the strongly connected components of the graph that `edges0`
describes, each after every component it depends on.

Each triple is a node, the key that names it, and the keys of the nodes it
depends on. A dependency key that names no node is ignored. Keys are expected
to be distinct, and nothing checks that they are: when two nodes share a key,
both appear in the result, but every dependency on that key reaches only one
of them.

-}
stronglyConnComp : List ( node, comparable, List comparable ) -> List (SCC node)
stronglyConnComp edges0 =
    List.map
        (\scc ->
            case scc of
                AcyclicSCC ( n, _, _ ) ->
                    AcyclicSCC n

                CyclicSCC triples ->
                    CyclicSCC (List.map (\( n, _, _ ) -> n) triples)
        )
        (stronglyConnCompR edges0)


{-| Returns the components as `stronglyConnComp` does, but with each node
still in its whole triple.

The triples are sorted by key and numbered by their place in that order, which
is what lets a dependency key be turned into a number by binary search.

-}
stronglyConnCompR : List ( node, comparable, List comparable ) -> List (SCC ( node, comparable, List comparable ))
stronglyConnCompR edges0 =
    case edges0 of
        [] ->
            []

        _ ->
            let
                sorted =
                    List.sortBy (\( _, k, _ ) -> k) edges0

                keys =
                    Array.fromList (List.map (\( _, k, _ ) -> k) sorted)

                triples =
                    Array.fromList sorted

                n =
                    Array.length keys

                keyToId : comparable -> Maybe Int
                keyToId target =
                    binarySearch keys target 0 (n - 1)

                ( fwd, trans, selfLoops ) =
                    buildGraphs triples keyToId n
            in
            kosaraju fwd trans selfLoops triples n



-- BINARY SEARCH


{-| Returns the index of `target` in `arr` between `lo` and `hi` inclusive, or
`Nothing` if it is not there.

`arr` must be in ascending order. When `target` occurs more than once, any one
of its indices may be returned.

-}
binarySearch : Array comparable -> comparable -> Int -> Int -> Maybe Int
binarySearch arr target lo hi =
    if lo > hi then
        Nothing

    else
        let
            mid =
                lo + (hi - lo) // 2
        in
        case Array.get mid arr of
            Nothing ->
                Nothing

            Just midVal ->
                if target == midVal then
                    Just mid

                else if target < midVal then
                    binarySearch arr target lo (mid - 1)

                else
                    binarySearch arr target (mid + 1) hi



-- GRAPH CONSTRUCTION


{-| Builds, for the `n` numbered triples, the forward adjacency, the reversed
adjacency and the set of vertices with an edge to themselves, the three parts
of an `IntGraph`.

`keyToId` turns each dependency key into a vertex number; a key it maps to
`Nothing` contributes no edge.

-}
buildGraphs :
    Array ( node, comparable, List comparable )
    -> (comparable -> Maybe Int)
    -> Int
    -> ( Array (List Int), Array (List Int), BitSet )
buildGraphs triples keyToId n =
    let
        result =
            Array.foldl
                (\( _, _, deps ) acc ->
                    let
                        edges =
                            List.filterMap keyToId deps

                        hasSelfLoop =
                            List.member acc.idx edges

                        newFwd =
                            CoreDict.insert acc.idx edges acc.fwd

                        newTrans =
                            List.foldl
                                (\target t ->
                                    let
                                        existing =
                                            CoreDict.get target t |> Maybe.withDefault []
                                    in
                                    CoreDict.insert target (acc.idx :: existing) t
                                )
                                acc.trans
                                edges

                        bOff =
                            modBy 32 acc.idx

                        wordWithBit =
                            if hasSelfLoop then
                                Bitwise.or acc.loopWord (Bitwise.shiftLeftBy bOff 1)

                            else
                                acc.loopWord

                        -- Self-loop bits build up in loopWord and are written a whole word at a time.
                        ( newLoops, newLoopWord ) =
                            if bOff == 31 || acc.idx == n - 1 then
                                ( BitSet.setWord (acc.idx // 32) wordWithBit acc.loops
                                , 0
                                )

                            else
                                ( acc.loops, wordWithBit )
                    in
                    { idx = acc.idx + 1
                    , fwd = newFwd
                    , trans = newTrans
                    , loops = newLoops
                    , loopWord = newLoopWord
                    }
                )
                { idx = 0, fwd = CoreDict.empty, trans = CoreDict.empty, loops = BitSet.fromSize n, loopWord = 0 }
                triples

        fwdArray =
            Array.initialize n (\i -> CoreDict.get i result.fwd |> Maybe.withDefault [])

        transArray =
            Array.initialize n (\i -> CoreDict.get i result.trans |> Maybe.withDefault [])
    in
    ( fwdArray, transArray, result.loops )



-- KOSARAJU'S ALGORITHM


{-| Returns the strongly connected components of the graph given by `fwd`,
`trans` and `selfLoops`, each after every component it has an edge to, with
each vertex replaced by its triple from `triples`.

This is the algorithm the module docstring describes, the same as
`stronglyConnCompInt` except that each vertex is looked up in `triples`.

-}
kosaraju :
    Array (List Int)
    -> Array (List Int)
    -> BitSet
    -> Array ( node, comparable, List comparable )
    -> Int
    -> List (SCC ( node, comparable, List comparable ))
kosaraju fwd trans selfLoops triples n =
    let
        rpo =
            reversePostOrder trans n

        ( _, sccs ) =
            List.foldl
                (\v ( visited, acc ) ->
                    if BitSet.member v visited then
                        ( visited, acc )

                    else
                        let
                            ( newVisited, component ) =
                                collectComponent fwd v visited
                        in
                        case component of
                            [ single ] ->
                                if BitSet.member single selfLoops then
                                    case Array.get single triples of
                                        Just triple ->
                                            ( newVisited, CyclicSCC [ triple ] :: acc )

                                        Nothing ->
                                            ( newVisited, acc )

                                else
                                    case Array.get single triples of
                                        Just triple ->
                                            ( newVisited, AcyclicSCC triple :: acc )

                                        Nothing ->
                                            ( newVisited, acc )

                            _ ->
                                ( newVisited
                                , CyclicSCC (List.filterMap (\i -> Array.get i triples) component) :: acc
                                )
                )
                ( BitSet.emptyWithSize n, [] )
                rpo
    in
    List.reverse sccs



-- REVERSE POST-ORDER via DFS on transposed graph


{-| One step still to be taken by the depth-first search in `rpoHelp`.

`Enter` visits a vertex, unless it has been visited already, and schedules its
neighbours ahead of its `Exit`.

`Exit` is reached once every neighbour pushed by its `Enter` has been dealt
with, which is the moment the search is finished with that vertex.

-}
type DfsWork
    = Enter Int
    | Exit Int


{-| Returns the vertices 0 to `n - 1` of the graph `adj` in reverse
post-order: depth-first searches are started from each unvisited vertex in
ascending order, and the vertex the searches finished with last comes first.
-}
reversePostOrder : Array (List Int) -> Int -> List Int
reversePostOrder adj n =
    let
        allVertices =
            List.range 0 (n - 1)

        ( _, result ) =
            List.foldl
                (\v ( visited, acc ) ->
                    if BitSet.member v visited then
                        ( visited, acc )

                    else
                        rpoHelp adj [ Enter v ] visited acc
                )
                ( BitSet.emptyWithSize n, [] )
                allVertices
    in
    result


{-| Runs the depth-first search whose pending steps are `stack`, returning the
vertices visited so far and `acc` with each vertex the search finishes with
put in front of it.
-}
rpoHelp : Array (List Int) -> List DfsWork -> BitSet -> List Int -> ( BitSet, List Int )
rpoHelp adj stack visited acc =
    case stack of
        [] ->
            ( visited, acc )

        (Exit v) :: rest ->
            rpoHelp adj rest visited (v :: acc)

        (Enter v) :: rest ->
            if BitSet.member v visited then
                rpoHelp adj rest visited acc

            else
                let
                    neighbors =
                        Maybe.withDefault [] (Array.get v adj)

                    newStack =
                        List.foldl (\n s -> Enter n :: s) (Exit v :: rest) neighbors
                in
                rpoHelp adj newStack (BitSet.insert v visited) acc



-- COLLECT ONE SCC COMPONENT via DFS on forward graph


{-| Returns, with `visited` extended, every vertex that can be reached in `adj`
from `start` without passing through a vertex `visited` already holds.

When `start` is taken in reverse post-order of the reversed graph and
`visited` holds the components already collected, those vertices are exactly
the component of `start`.

-}
collectComponent : Array (List Int) -> Int -> BitSet -> ( BitSet, List Int )
collectComponent adj start visited =
    collectHelp adj [ start ] visited []


{-| Runs the depth-first search whose pending vertices are `stack`, returning
`visited` and `acc` with each newly visited vertex added; `acc` gains them in
front, so it ends in the reverse of the order they were visited.
-}
collectHelp : Array (List Int) -> List Int -> BitSet -> List Int -> ( BitSet, List Int )
collectHelp adj stack visited acc =
    case stack of
        [] ->
            ( visited, acc )

        v :: rest ->
            if BitSet.member v visited then
                collectHelp adj rest visited acc

            else
                let
                    neighbors =
                        Maybe.withDefault [] (Array.get v adj)

                    newStack =
                        List.foldl (\n s -> n :: s) rest neighbors
                in
                collectHelp adj newStack (BitSet.insert v visited) (v :: acc)
