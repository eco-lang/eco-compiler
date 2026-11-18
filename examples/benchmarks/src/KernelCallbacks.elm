module KernelCallbacks exposing (bench)

{-| Library functions that call a small function once per element, over `n` elements:
`List.sortBy` on a record field, `Array.initialize`, `Array.map` and `Array.foldl`, and
`List.map2`. Each function is a one-liner, so the work is the call of it from the library.

Checked at every size: the sorted keys are `0 .. n-1` (the keys are a permutation when `n` is
not a multiple of 7919), the array sums are `n(n-1)/2` and twice that, and the `List.map2`
products are summed again with `List.foldl`. The closed form halves the even factor first,
because `//` on the official compiler's JavaScript truncates to 32 bits.

-}

import Array


type alias Item =
    { key : Int, payload : Int }


bench : Int -> Bool
bench n =
    let
        items : List Item
        items =
            List.map (\i -> { key = modBy n (i * 7919 + 13), payload = i }) (List.range 0 (n - 1))

        sorted =
            List.sortBy .key items

        sortedOk =
            List.map .key sorted == List.range 0 (n - 1)

        arr =
            Array.initialize n (\i -> i)

        sum1 =
            Array.foldl (\x acc -> x + acc) 0 arr

        sum2 =
            Array.foldl (\x acc -> x + acc) 0 (Array.map (\x -> x * 2) arr)

        xs =
            List.range 0 (n - 1)

        squares =
            List.sum (List.map2 (\a b -> a * b) xs xs)

        pairs =
            if modBy 2 n == 0 then
                (n // 2) * (n - 1)

            else
                n * ((n - 1) // 2)
    in
    sortedOk
        && (sum1 == pairs)
        && (sum2 == 2 * pairs)
        && (squares == List.foldl (\x acc -> acc + x * x) 0 xs)
