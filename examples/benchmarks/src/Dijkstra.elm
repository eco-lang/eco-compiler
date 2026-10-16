module Dijkstra exposing (bench)

{-| Shortest paths from one corner of an `n` x `n` grid whose edges have generated weights 1 to 9.
The distances are a `Dict (Int, Int) Int`, and the frontier is Dial's bucket queue, a
`Dict Int (List (Int, Int))` from distance to the nodes waiting at it (elm/core's `Dict` has no
cheap minimum, and the weights are small integers). Dict inserts, lookups and updates with tuple
keys.

Checked at every size by the shortest-path certificate, which holds exactly when every distance
is the true one: the source is at 0, every node has a distance, no edge `u -> v` has
`dist v > dist u + w`, and every other node has a neighbour `u` with `dist v == dist u + w`.

-}

import Dict exposing (Dict)


type alias Node =
    ( Int, Int )


{-| The weight of the edge between two neighbouring nodes, the same in both directions.
-}
weight : Int -> Node -> Node -> Int
weight n ( ax, ay ) ( bx, by ) =
    let
        a =
            ax * n + ay

        b =
            bx * n + by
    in
    1 + modBy 9 (min a b * 7919 + max a b * 104729 + 17)


neighbours : Int -> Node -> List Node
neighbours n ( x, y ) =
    List.filter (\( a, b ) -> a >= 0 && a < n && b >= 0 && b < n) [ ( x + 1, y ), ( x - 1, y ), ( x, y + 1 ), ( x, y - 1 ) ]


push : Int -> Node -> Dict Int (List Node) -> Dict Int (List Node)
push d node buckets =
    Dict.update d (\nodes -> Just (node :: Maybe.withDefault [] nodes)) buckets


{-| Dial's algorithm: settle the nodes of bucket `d`, then move on to `d + 1`.
-}
search : Int -> Int -> Int -> Dict Int (List Node) -> Dict Node Int -> Dict Node Int
search n d remaining buckets dist =
    if remaining <= 0 then
        dist

    else
        case Dict.get d buckets of
            Nothing ->
                search n (d + 1) remaining buckets dist

            Just [] ->
                search n (d + 1) remaining (Dict.remove d buckets) dist

            Just (node :: rest) ->
                let
                    others =
                        Dict.insert d rest buckets
                in
                if Dict.get node dist /= Just d then
                    search n d remaining others dist

                else
                    let
                        relax next ( bs, ds ) =
                            let
                                nd =
                                    d + weight n node next
                            in
                            case Dict.get next ds of
                                Just old ->
                                    if nd < old then
                                        ( push nd next bs, Dict.insert next nd ds )

                                    else
                                        ( bs, ds )

                                Nothing ->
                                    ( push nd next bs, Dict.insert next nd ds )

                        ( buckets2, dist2 ) =
                            List.foldl relax ( others, dist ) (neighbours n node)
                    in
                    search n d (remaining - 1) buckets2 dist2


distances : Int -> Dict Node Int
distances n =
    search n 0 (n * n) (Dict.singleton 0 [ ( 0, 0 ) ]) (Dict.singleton ( 0, 0 ) 0)


certified : Int -> Dict Node Int -> Bool
certified n dist =
    let
        at node =
            Dict.get node dist

        nodeOk node =
            case at node of
                Nothing ->
                    False

                Just dv ->
                    let
                        via u =
                            Maybe.map (\du -> du + weight n u node) (at u)

                        candidates =
                            List.filterMap via (neighbours n node)
                    in
                    List.all (\c -> dv <= c) candidates
                        && (node == ( 0, 0 ) || List.member dv candidates)

        rows x =
            List.all (\y -> nodeOk ( x, y )) (List.range 0 (n - 1))
    in
    at ( 0, 0 ) == Just 0 && Dict.size dist == n * n && List.all rows (List.range 0 (n - 1))


bench : Int -> Bool
bench n =
    certified n (distances n)
