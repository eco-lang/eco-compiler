module Compiler.Graph exposing
    ( SCC(..)
    , stronglyConnComp
    , stronglyConnCompR
    , flattenSCC
    , flattenSCCs
    )

{-| Self-contained Kosaraju's SCC algorithm.

Uses only Array and Set from elm/core – no external graph or tree libraries.
Vertices are mapped to contiguous 0..N-1 IDs via sorted key lookup.
All traversals use explicit stacks (tail-recursive, stack-safe).
-}

import Array exposing (Array)
import Set exposing (Set)


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
    -> ( Array (List Int), Array (List Int), Set Int )
buildGraphs triples keyToId n =
    let
        emptyAdj =
            Array.repeat n []

        result =
            Array.foldl
                (\( _, _, deps ) acc ->
                    let
                        edges =
                            List.filterMap keyToId deps

                        hasSelfLoop =
                            List.any (\e -> e == acc.idx) edges

                        newFwd =
                            Array.set acc.idx edges acc.fwd

                        newTrans =
                            List.foldl
                                (\target t ->
                                    case Array.get target t of
                                        Just existing ->
                                            Array.set target (acc.idx :: existing) t

                                        Nothing ->
                                            t
                                )
                                acc.trans
                                edges

                        newLoops =
                            if hasSelfLoop then
                                Set.insert acc.idx acc.loops

                            else
                                acc.loops
                    in
                    { idx = acc.idx + 1
                    , fwd = newFwd
                    , trans = newTrans
                    , loops = newLoops
                    }
                )
                { idx = 0, fwd = emptyAdj, trans = emptyAdj, loops = Set.empty }
                triples
    in
    ( result.fwd, result.trans, result.loops )



-- KOSARAJU'S ALGORITHM


kosaraju :
    Array (List Int)
    -> Array (List Int)
    -> Set Int
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
                    if Set.member v visited then
                        ( visited, acc )

                    else
                        let
                            ( newVisited, component ) =
                                collectComponent fwd v visited
                        in
                        case component of
                            [ single ] ->
                                if Set.member single selfLoops then
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
                ( Set.empty, [] )
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
                    if Set.member v visited then
                        ( visited, acc )

                    else
                        rpoHelp adj [ Enter v ] visited acc
                )
                ( Set.empty, [] )
                allVertices
    in
    result


rpoHelp : Array (List Int) -> List DfsWork -> Set Int -> List Int -> ( Set Int, List Int )
rpoHelp adj stack visited acc =
    case stack of
        [] ->
            ( visited, acc )

        (Exit v) :: rest ->
            rpoHelp adj rest visited (v :: acc)

        (Enter v) :: rest ->
            if Set.member v visited then
                rpoHelp adj rest visited acc

            else
                let
                    neighbors =
                        Maybe.withDefault [] (Array.get v adj)

                    childWork =
                        List.map Enter neighbors
                in
                rpoHelp adj (childWork ++ (Exit v :: rest)) (Set.insert v visited) acc



-- COLLECT ONE SCC COMPONENT via DFS on forward graph


collectComponent : Array (List Int) -> Int -> Set Int -> ( Set Int, List Int )
collectComponent adj start visited =
    collectHelp adj [ start ] visited []


collectHelp : Array (List Int) -> List Int -> Set Int -> List Int -> ( Set Int, List Int )
collectHelp adj stack visited acc =
    case stack of
        [] ->
            ( visited, acc )

        v :: rest ->
            if Set.member v visited then
                collectHelp adj rest visited acc

            else
                let
                    neighbors =
                        Maybe.withDefault [] (Array.get v adj)
                in
                collectHelp adj (neighbors ++ rest) (Set.insert v visited) (v :: acc)
