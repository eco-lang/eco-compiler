module FloydWarshall exposing (bench)

{-| Floyd-Warshall all-pairs shortest paths over a flat `Array Int` of `n * n` distances: `n^3`
`Array.get`s and up to as many `Array.set`s. The graph is a ring of `n` nodes with unit edges plus
`n / 4` generated chords, also of unit length.

Checked at every size: the matrix must be symmetric with a zero diagonal, and four of its rows
must equal the distances breadth-first search finds from those nodes over the same edges (BFS
gives exact distances when every edge has length 1).

-}

import Array exposing (Array)


infinity : Int
infinity =
    1000000000


chords : Int -> List ( Int, Int )
chords n =
    List.map (\k -> ( modBy n (k * 7919 + 3), modBy n (k * 104729 + 11) )) (List.range 1 (n // 4))


edges : Int -> List ( Int, Int )
edges n =
    List.filter (\( a, b ) -> a /= b) (List.map (\i -> ( i, modBy n (i + 1) )) (List.range 0 (n - 1)) ++ chords n)


initial : Int -> Array Int
initial n =
    List.foldl
        (\( a, b ) d -> d |> Array.set (a * n + b) 1 |> Array.set (b * n + a) 1)
        (Array.initialize (n * n)
            (\i ->
                if i // n == modBy n i then
                    0

                else
                    infinity
            )
        )
        (edges n)


relax : Int -> Int -> Array Int -> Array Int
relax n k dist =
    let
        go i j d =
            if i >= n then
                d

            else if j >= n then
                go (i + 1) 0 d

            else
                let
                    at x y =
                        Maybe.withDefault infinity (Array.get (x * n + y) d)

                    through =
                        at i k + at k j
                in
                if through < at i j then
                    go i (j + 1) (Array.set (i * n + j) through d)

                else
                    go i (j + 1) d
    in
    go 0 0 dist


allPairs : Int -> Array Int
allPairs n =
    List.foldl (relax n) (initial n) (List.range 0 (n - 1))


bfs : Int -> Array (List Int) -> Int -> Array Int
bfs n adjacency source =
    let
        go frontier depth dist =
            case frontier of
                [] ->
                    dist

                _ ->
                    let
                        visit u ( nf, d ) =
                            List.foldl
                                (\v ( f, dd ) ->
                                    if Array.get v dd == Just infinity then
                                        ( v :: f, Array.set v (depth + 1) dd )

                                    else
                                        ( f, dd )
                                )
                                ( nf, d )
                                (Maybe.withDefault [] (Array.get u adjacency))

                        ( frontier2, dist2 ) =
                            List.foldl visit ( [], dist ) frontier
                    in
                    go frontier2 (depth + 1) dist2
    in
    go [ source ] 0 (Array.set source 0 (Array.repeat n infinity))


bench : Int -> Bool
bench n =
    let
        dist =
            allPairs n

        at i j =
            Maybe.withDefault -1 (Array.get (i * n + j) dist)

        adjacency =
            List.foldl
                (\( a, b ) adj ->
                    adj
                        |> Array.set a (b :: Maybe.withDefault [] (Array.get a adj))
                        |> Array.set b (a :: Maybe.withDefault [] (Array.get b adj))
                )
                (Array.repeat n [])
                (edges n)

        nodes =
            List.range 0 (n - 1)

        rowMatches s =
            List.map (at s) nodes == Array.toList (bfs n adjacency s)

        symmetric =
            List.all (\i -> List.all (\j -> at i j == at j i) nodes) nodes
    in
    symmetric
        && List.all (\i -> at i i == 0) nodes
        && List.all rowMatches (List.map (\k -> modBy n (k * 31)) [ 0, 1, 2, 3 ])
