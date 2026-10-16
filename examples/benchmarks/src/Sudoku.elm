module Sudoku exposing (bench)

{-| Sudoku by constraint propagation and search, after Norvig's solver: each cell's candidates are
a `Set Int`, assigning a digit eliminates it from the cell's 20 peers, a cell left with one
candidate assigns it in turn, and search tries the candidates of the cell with fewest. `Set`
membership, removal and size, inside persistent `Array`s of sets.

`n` puzzles are generated: a valid grid, shuffled (digits relabelled, rows swapped within bands
and columns within stacks, which keep it valid), with all but 26 cells blanked. Every solution is
checked directly, at every size: every cell is solved, every row, column and box holds 1 to 9,
and every given is kept. (A generated puzzle can have several solutions; any of them passes.)

-}

import Array exposing (Array)
import Set exposing (Set)


type alias Grid =
    Array (Set Int)


row : Int -> Int
row cell =
    cell // 9


col : Int -> Int
col cell =
    modBy 9 cell


box : Int -> Int
box cell =
    (row cell // 3) * 3 + col cell // 3


units : List (List Int)
units =
    let
        all =
            List.range 0 80
    in
    List.concatMap
        (\i ->
            [ List.filter (\c -> row c == i) all
            , List.filter (\c -> col c == i) all
            , List.filter (\c -> box c == i) all
            ]
        )
        (List.range 0 8)


peers : Array (List Int)
peers =
    Array.initialize 81
        (\cell ->
            List.filter (\c -> c /= cell && (row c == row cell || col c == col cell || box c == box cell)) (List.range 0 80)
        )


cands : Int -> Grid -> Set Int
cands cell grid =
    Maybe.withDefault Set.empty (Array.get cell grid)


{-| Remove digit `d` from `cell`; a cell left with one candidate has it eliminated from its peers.
-}
eliminate : Int -> Int -> Grid -> Maybe Grid
eliminate d cell grid =
    let
        current =
            cands cell grid
    in
    if not (Set.member d current) then
        Just grid

    else
        let
            left =
                Set.remove d current

            grid2 =
                Array.set cell left grid
        in
        case Set.toList left of
            [] ->
                Nothing

            [ only ] ->
                eliminateAll only (Maybe.withDefault [] (Array.get cell peers)) grid2

            _ ->
                Just grid2


eliminateAll : Int -> List Int -> Grid -> Maybe Grid
eliminateAll d cells grid =
    case cells of
        [] ->
            Just grid

        c :: rest ->
            case eliminate d c grid of
                Just g ->
                    eliminateAll d rest g

                Nothing ->
                    Nothing


assign : Int -> Int -> Grid -> Maybe Grid
assign cell d grid =
    Set.foldl
        (\other acc -> Maybe.andThen (eliminate other cell) acc)
        (Just grid)
        (Set.remove d (cands cell grid))


search : Grid -> Maybe Grid
search grid =
    let
        open =
            Array.toIndexedList grid
                |> List.filter (\( _, s ) -> Set.size s > 1)
                |> List.sortBy (\( _, s ) -> Set.size s)
    in
    case open of
        [] ->
            Just grid

        ( cell, options ) :: _ ->
            firstSolution cell (Set.toList options) grid


firstSolution : Int -> List Int -> Grid -> Maybe Grid
firstSolution cell options grid =
    case options of
        [] ->
            Nothing

        d :: rest ->
            case Maybe.andThen search (assign cell d grid) of
                Just solved ->
                    Just solved

                Nothing ->
                    firstSolution cell rest grid


solve : List ( Int, Int ) -> Maybe Grid
solve givens =
    List.foldl
        (\( cell, d ) acc -> Maybe.andThen (assign cell d) acc)
        (Just (Array.repeat 81 (Set.fromList (List.range 1 9))))
        givens
        |> Maybe.andThen search


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| A shuffled valid grid, as 81 digits, and the seed after it.
-}
solvedGrid : Int -> ( Array Int, Int )
solvedGrid seed0 =
    let
        base r c =
            modBy 9 (r * 3 + r // 3 + c)

        -- a permutation of 0 .. 8 by repeated swaps
        permute k seed perm =
            if k <= 0 then
                ( perm, seed )

            else
                let
                    s1 =
                        next seed

                    s2 =
                        next s1

                    i =
                        modBy 9 s1

                    j =
                        modBy 9 s2

                    pi =
                        Maybe.withDefault i (Array.get i perm)

                    pj =
                        Maybe.withDefault j (Array.get j perm)
                in
                permute (k - 1) s2 (perm |> Array.set i pj |> Array.set j pi)

        -- swap two lines within each group of three
        groupSwap seed =
            let
                s1 =
                    next seed

                s2 =
                    next s1

                a =
                    modBy 3 s1

                b =
                    modBy 3 s2
            in
            ( \line ->
                let
                    group =
                        line // 3

                    within =
                        modBy 3 line

                    swapped =
                        if within == a then
                            b

                        else if within == b then
                            a

                        else
                            within
                in
                group * 3 + swapped
            , s2
            )

        ( digits, seedA ) =
            permute 20 seed0 (Array.fromList (List.range 0 8))

        ( rowMap, seedB ) =
            groupSwap seedA

        ( colMap, seedC ) =
            groupSwap seedB
    in
    ( Array.initialize 81 (\cell -> 1 + Maybe.withDefault 0 (Array.get (base (rowMap (row cell)) (colMap (col cell))) digits))
    , seedC
    )


{-| Puzzle `k`: 26 givens of a shuffled grid.
-}
puzzle : Int -> List ( Int, Int )
puzzle k =
    let
        ( grid, seed ) =
            solvedGrid (k * 7919 + 1)

        pickCells count s chosen =
            if Set.size chosen >= count then
                chosen

            else
                let
                    s2 =
                        next s
                in
                pickCells count s2 (Set.insert (modBy 81 s2) chosen)
    in
    pickCells 26 seed Set.empty
        |> Set.toList
        |> List.map (\cell -> ( cell, Maybe.withDefault 0 (Array.get cell grid) ))


valid : List ( Int, Int ) -> Grid -> Bool
valid givens grid =
    let
        digit cell =
            case Set.toList (cands cell grid) of
                [ d ] ->
                    d

                _ ->
                    0

        unitOk unit =
            List.sort (List.map digit unit) == List.range 1 9
    in
    List.all unitOk units && List.all (\( cell, d ) -> digit cell == d) givens


bench : Int -> Bool
bench n =
    List.all
        (\k ->
            let
                givens =
                    puzzle k
            in
            case solve givens of
                Just grid ->
                    valid givens grid

                Nothing ->
                    False
        )
        (List.range 1 n)
