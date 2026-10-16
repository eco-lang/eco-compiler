module ListFold exposing (bench)

{-| List traversal: build a range and fold it to a number, with no other allocation. The fold
keeps the running sum modulo 1000000007, so it ends at `triangle n` modulo the same.
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
        |> List.foldl (\x a -> modBy 1000000007 (a + x)) 0
    )
        == modBy 1000000007 (triangle n)
