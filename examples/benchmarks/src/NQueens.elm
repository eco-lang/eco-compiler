module NQueens exposing (bench)

{-| n-queens: count every way to place `n` queens on an n x n board with no two attacking each
other, by backtracking one row at a time. Recursion and short lists. The counts for boards up to
18 x 18 are known (OEIS A000170); larger boards fail the check.
-}


{-| Whether a queen in column `col` is safe from the queens already placed, nearest row first.
-}
safe : Int -> List Int -> Bool
safe col placed =
    let
        go distance qs =
            case qs of
                [] ->
                    True

                q :: rest ->
                    q /= col && abs (q - col) /= distance && go (distance + 1) rest
    in
    go 1 placed


solutions : Int -> Int -> List Int -> Int
solutions n row placed =
    if row == n then
        1

    else
        List.foldl
            (\col total ->
                if safe col placed then
                    total + solutions n (row + 1) (col :: placed)

                else
                    total
            )
            0
            (List.range 0 (n - 1))


{-| The number of solutions for boards of size 0 to 18 (OEIS A000170).
-}
known : List Int
known =
    [ 1, 1, 0, 0, 2, 10, 4, 40, 92, 352, 724, 2680, 14200, 73712, 365596, 2279184, 14772512, 95815104, 666090624 ]


bench : Int -> Bool
bench n =
    List.head (List.drop n known) == Just (solutions n 0 [])
