module Compiler.Graph exposing
    ( SCC(..)
    , IntGraph
    , stronglyConnComp
    , stronglyConnCompR
    , stronglyConnCompInt
    , fromAdjacency
    , flattenSCC
    , flattenSCCs
    )

{-| Self-contained Kosaraju's SCC algorithm.

Uses Array and BitSet – no external graph or tree libraries.
Vertices are mapped to contiguous 0..N-1 IDs via sorted key lookup.
All traversals use explicit stacks (tail-recursive, stack-safe).
-}

import Array exposing (Array)
import Bitwise
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Dict as CoreDict


type SCC vertex
    = AcyclicSCC vertex
    | CyclicSCC (List vertex)


flattenSCCs : List (SCC a) -> List a
flattenSCCs =
    List.concatMap flattenSCC


flattenSCC : SCC vertex -> List vertex
flattenSCC component =
    case component of
        AcyclicSCC v ->
            [ v ]

        CyclicSCC vs ->
            vs


type alias IntGraph =
    { fwd : Array (List Int)
    , trans : Array (List Int)
    , selfLoops : BitSet
    , size : Int
    }


fromAdjacency : Array (List Int) -> Array (List Int) -> BitSet -> Int -> IntGraph
fromAdjacency fwd trans selfLoops size =
    { fwd = fwd, trans = trans, selfLoops = selfLoops, size = size }


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

                -- Build forward adjacency, transposed adjacency, and self-loop set in one pass
                ( fwd, trans, selfLoops ) =
                    buildGraphs triples keyToId n
            in
            kosaraju fwd trans selfLoops triples n



-- BINARY SEARCH


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


buildGraphs :
    Array ( node, comparable, List comparable )
    -> (comparable -> Maybe Int)
    -> Int
    -> ( Array (List Int), Array (List Int), BitSet )
buildGraphs triples keyToId n =
    let
        -- Phase 1: Accumulate edges in Dicts (O(E log E) dict ops instead of O(E) persistent-array copies)
        result =
            Array.foldl
                (\( _, _, deps ) acc ->
                    let
                        edges =
                            List.filterMap keyToId deps

                        hasSelfLoop =
                            List.any (\e -> e == acc.idx) edges

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

        -- Phase 2: Convert Dicts to Arrays in one pass
        fwdArray =
            Array.initialize n (\i -> CoreDict.get i result.fwd |> Maybe.withDefault [])

        transArray =
            Array.initialize n (\i -> CoreDict.get i result.trans |> Maybe.withDefault [])
    in
    ( fwdArray, transArray, result.loops )



-- KOSARAJU'S ALGORITHM


kosaraju :
    Array (List Int)
    -> Array (List Int)
    -> BitSet
    -> Array ( node, comparable, List comparable )
    -> Int
    -> List (SCC ( node, comparable, List comparable ))
kosaraju fwd trans selfLoops triples n =
    let
        -- Step 1: Reverse post-order on transposed graph
        rpo =
            reversePostOrder trans n

        -- Step 2: Collect SCCs by DFS on forward graph in reverse post-order
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


type DfsWork
    = Enter Int
    | Exit Int


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


collectComponent : Array (List Int) -> Int -> BitSet -> ( BitSet, List Int )
collectComponent adj start visited =
    collectHelp adj [ start ] visited []


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
