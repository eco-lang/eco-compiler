module ListFilter exposing (bench)

{-| List allocation: build a range, filter it (keeping a third as a new list), then sum. The
multiples of 3 up to `n` are `3 * (1 .. m)` for `m = n // 3`, which sum to `3 * triangle m`.
-}


{-| `1 + 2 + ... + k`. The even factor is halved first: on the JavaScript backends `//` truncates
to 32 bits, so `k * (k + 1) // 2` would be wrong once the product passes 2^31.
-}
triangle : Int -> Int
triangle k =
    if modBy 2 k == 0 then
        (k // 2) * (k + 1)

    else
        k * ((k + 1) // 2)


bench : Int -> Bool
bench n =
    (List.range 1 n
        |> List.filter (\x -> modBy 3 x == 0)
        |> List.sum
    )
        == 3 * triangle (n // 3)
