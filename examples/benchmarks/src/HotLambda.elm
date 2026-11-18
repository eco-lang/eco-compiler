module HotLambda exposing (bench)

{-| `n` calls of a small function that passes functions capturing nothing to `List.foldl`,
`List.map` and `List.filter` over a three-element list. Each call evaluates those functions
afresh, so the cost is in making function values, not in the lists. (eco interns a function
value that captures nothing, so each evaluation is a lookup.)

Checked at every size (2 or more) by a closed form: each `x` counts as `3x` in up to three
calls, unless it is a multiple of 5. The closed form halves the even factor before multiplying,
because `//` on the official compiler's JavaScript truncates to 32 bits.

-}


small : Int -> Int
small i =
    [ i, i + 1, i + 2 ]
        |> List.map (\x -> x * 3)
        |> List.filter (\x -> modBy 5 x /= 0)
        |> List.foldl (\x acc -> x + acc) 0


{-| The sum of `small i` for `i` in `0 .. n-1`, without `small`: each `3x` with `x` not a
multiple of 5, for `x` in `i .. i+2`.
-}
expected : Int -> Int
expected n =
    let
        sumThrees : Int -> Int
        sumThrees k =
            -- The sum of 3x over 0 <= x < k with x not a multiple of 5.
            let
                all =
                    3 * pairs k

                fives =
                    (k + 4) // 5

                multiples =
                    15 * pairs fives
            in
            all - multiples
    in
    -- x appears in calls x-2, x-1 and x that lie in 0 .. n-1: three times for 2 <= x <= n-1,
    -- twice for x = 1 and x = n, once for x = 0 and x = n+1.
    3 * sumThrees (n + 2)
        - 2 * term 0
        - term 1
        - term n
        - 2 * term (n + 1)


{-| `k(k-1)/2`, exactly. -}
pairs : Int -> Int
pairs k =
    if modBy 2 k == 0 then
        (k // 2) * (k - 1)

    else
        k * ((k - 1) // 2)


term : Int -> Int
term x =
    if modBy 5 x == 0 then
        0

    else
        3 * x


bench : Int -> Bool
bench n =
    let
        go : Int -> Int -> Int
        go i acc =
            if i >= n then
                acc

            else
                go (i + 1) (acc + small i)
    in
    go 0 0 == expected n
