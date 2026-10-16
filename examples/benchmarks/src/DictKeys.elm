module DictKeys exposing (benchInt, benchString, benchTuple)

{-| The same `Dict` workload with three key types, to isolate the cost of comparing keys: insert
`n` keys, look up `n` keys (half of them present), and fold the values. `dict-int` keys are
`Int`s, `dict-string` keys the same numbers as decimal `String`s, and `dict-tuple` keys
`(Int, Int)` pairs. On eco's native backend every comparison goes through the generic compare,
which resolves both operands.

Checked at every size against the generator, with no `Dict`: the value sum and the hit count
are computed directly (key `k` is in the dict exactly when `k < n`).

-}

import Dict exposing (Dict)


{-| The `i`-th key and value: keys are a permutation of `0 .. n-1`, so inserts come in no order.
-}
keyAt : Int -> Int -> Int
keyAt n i =
    modBy n (i * 7919 + 13)


valueOf : Int -> Int
valueOf k =
    modBy 9973 (k * 31)


{-| The keys looked up: every other one is `n` or more, so it misses.
-}
lookupAt : Int -> Int -> Int
lookupAt n i =
    if modBy 2 i == 0 then
        keyAt n i

    else
        n + i


run : (Int -> comparable) -> Int -> ( Int, Int )
run toKey n =
    let
        d =
            List.foldl (\i acc -> insertKey (keyAt n i) acc) Dict.empty (List.range 0 (n - 1))

        insertKey k acc =
            Dict.insert (toKey k) (valueOf k) acc

        hits =
            List.foldl
                (\i acc ->
                    case Dict.get (toKey (lookupAt n i)) d of
                        Just _ ->
                            acc + 1

                        Nothing ->
                            acc
                )
                0
                (List.range 0 (n - 1))
    in
    ( Dict.foldl (\_ v s -> s + v) 0 d, hits )


{-| The value sum and hit count, without a `Dict`. 7919 is prime, so `keyAt n` is a
permutation of `0 .. n-1` unless `n` is a multiple of 7919; then the distinct keys are found by
sorting.
-}
expected : Int -> ( Int, Int )
expected n =
    let
        keys =
            if modBy 7919 n /= 0 then
                List.range 0 (n - 1)

            else
                dedupe (List.sort (List.map (keyAt n) (List.range 0 (n - 1))))
    in
    ( List.foldl (\k s -> s + valueOf k) 0 keys, (n + 1) // 2 )


dedupe : List Int -> List Int
dedupe sorted =
    case sorted of
        a :: b :: rest ->
            if a == b then
                dedupe (b :: rest)

            else
                a :: dedupe (b :: rest)

        _ ->
            sorted


benchInt : Int -> Bool
benchInt n =
    run identity n == expected n


benchString : Int -> Bool
benchString n =
    run String.fromInt n == expected n


benchTuple : Int -> Bool
benchTuple n =
    run (\k -> ( k // 1000, modBy 1000 k )) n == expected n
