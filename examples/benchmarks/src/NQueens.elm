module NQueens exposing (bench)

{-| n-queens: count every way to place `n` queens on an n x n board with no two attacking each
other, by backtracking one row at a time. Recursion and short lists.
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


bench : Int -> Int
bench n =
    solutions n 0 []
