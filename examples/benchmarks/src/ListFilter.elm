module ListFilter exposing (bench)

{-| List allocation: build a range, filter it (keeping a third as a new list), then sum.
-}


bench : Int -> Int
bench n =
    List.range 1 n
        |> List.filter (\x -> modBy 3 x == 0)
        |> List.sum
