module ListMap exposing (bench)

{-| List allocation: build a range, map over it (a new list), then sum.
-}


bench : Int -> Int
bench n =
    List.range 1 n
        |> List.map (\x -> x * 2)
        |> List.sum
