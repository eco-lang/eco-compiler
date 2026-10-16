module ListMap exposing (bench)

{-| List allocation: build a range, map over it (a new list), then sum. The sum of `2 * x` over
`1 .. n` is `n * (n + 1)`.
-}


bench : Int -> Bool
bench n =
    (List.range 1 n
        |> List.map (\x -> x * 2)
        |> List.sum
    )
        == n * (n + 1)
