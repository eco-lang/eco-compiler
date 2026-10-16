module FloodFill exposing (bench)

{-| Flood fill: breadth-first search from a corner of a generated `n` x `n` grid of open and
walled cells (30 % walled at random, well below the 41 % at which the open cells stop forming
one large component, so the fill reaches most of the grid), with the visited cells in a
`Set (Int, Int)` and the frontier as lists. `Set` insertion and membership with tuple keys.

Checked at every size against a different algorithm: the number of cells reached must equal the
size of the corner's component found by union-find over an `Array Int` of parents, with no `Set`
and no search.

-}

import Array exposing (Array)
import Set exposing (Set)


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| A pseudo-random value for a cell. Not linear in `x` and `y` (a linear one walls the grid
along lattice lines); every intermediate value stays below 2^53.
-}
hash : Int -> Int -> Int
hash x y =
    let
        hx =
            next (next (x + 1))

        hy =
            next (next (y + 1000003))
    in
    next (modBy 65536 hx * modBy 65536 hy + hx // 65536 + hy)


{-| Whether cell `(x, y)` is open; the 3 x 3 corner always is, so that the fill does not start
sealed in a small pocket.
-}
open : Int -> Int -> Int -> Bool
open n x y =
    x >= 0 && x < n && y >= 0 && y < n && ((x < 3 && y < 3) || modBy 100 (hash x y) >= 30)


neighbours : ( Int, Int ) -> List ( Int, Int )
neighbours ( x, y ) =
    [ ( x + 1, y ), ( x - 1, y ), ( x, y + 1 ), ( x, y - 1 ) ]


fill : Int -> Set ( Int, Int )
fill n =
    let
        go frontier visited =
            case frontier of
                [] ->
                    visited

                _ ->
                    let
                        step cell ( nextFrontier, seen ) =
                            List.foldl
                                (\( x, y ) ( nf, s ) ->
                                    if open n x y && not (Set.member ( x, y ) s) then
                                        ( ( x, y ) :: nf, Set.insert ( x, y ) s )

                                    else
                                        ( nf, s )
                                )
                                ( nextFrontier, seen )
                                (neighbours cell)

                        ( frontier2, visited2 ) =
                            List.foldl step ( [], visited ) frontier
                    in
                    go frontier2 visited2
    in
    go [ ( 0, 0 ) ] (Set.singleton ( 0, 0 ))


{-| The root of `i`'s set, halving the path on the way.
-}
find : Int -> Array Int -> ( Int, Array Int )
find i parents =
    let
        p =
            Maybe.withDefault i (Array.get i parents)
    in
    if p == i then
        ( i, parents )

    else
        let
            grand =
                Maybe.withDefault p (Array.get p parents)
        in
        find grand (Array.set i grand parents)


union : Int -> Int -> Array Int -> Array Int
union a b parents =
    let
        ( ra, p1 ) =
            find a parents

        ( rb, p2 ) =
            find b p1
    in
    if ra == rb then
        p2

    else
        Array.set (max ra rb) (min ra rb) p2


componentSize : Int -> Int
componentSize n =
    let
        index x y =
            x * n + y

        link x y parents =
            if not (open n x y) then
                parents

            else
                parents
                    |> (\ps ->
                            if open n (x + 1) y then
                                union (index x y) (index (x + 1) y) ps

                            else
                                ps
                       )
                    |> (\ps ->
                            if open n x (y + 1) then
                                union (index x y) (index x (y + 1)) ps

                            else
                                ps
                       )

        linked =
            List.foldl (\x ps -> List.foldl (\y p -> link x y p) ps (List.range 0 (n - 1))) (Array.initialize (n * n) identity) (List.range 0 (n - 1))

        ( root, final ) =
            find 0 linked

        count x y ( total, ps ) =
            if open n x y then
                let
                    ( r, ps2 ) =
                        find (index x y) ps
                in
                if r == root then
                    ( total + 1, ps2 )

                else
                    ( total, ps2 )

            else
                ( total, ps )
    in
    Tuple.first (List.foldl (\x acc -> List.foldl (\y a -> count x y a) acc (List.range 0 (n - 1))) ( 0, final ) (List.range 0 (n - 1)))


bench : Int -> Bool
bench n =
    Set.size (fill n) == componentSize n
