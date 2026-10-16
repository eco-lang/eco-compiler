module ShuffleSort exposing (bench)

{-| Fisher-Yates shuffle of `0 .. n-1` in an `Array Int` (`n` random `Array.get`/`Array.set`
pairs), then `List.sort` of `Array.toList`.

Checked at every size: the sorted result must be exactly `0 .. n-1` (so the shuffle kept every
element), and the last 100 positions of the shuffle must match an independent replay of its
first 100 swaps over a sparse `Dict` (each swap at position `i` only touches positions up to
`i`, so position `n-1` is final after the first swap, `n-2` after the second, and so on).

-}

import Array exposing (Array)
import Dict


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| The swap partner for position `i`, in `0 .. i`.
-}
partner : Int -> Int -> Int
partner i seed =
    modBy (i + 1) seed


shuffle : Int -> Array Int
shuffle n =
    let
        go i seed a =
            if i <= 0 then
                a

            else
                let
                    s =
                        next seed

                    j =
                        partner i s

                    ai =
                        Maybe.withDefault 0 (Array.get i a)

                    aj =
                        Maybe.withDefault 0 (Array.get j a)
                in
                go (i - 1) s (a |> Array.set i aj |> Array.set j ai)
    in
    go (n - 1) 1 (Array.initialize n identity)


{-| The final values of the last `k` positions, replaying only the first `k` swaps.
-}
replay : Int -> Int -> List Int
replay n k =
    let
        at d p =
            Maybe.withDefault p (Dict.get p d)

        go i seed d acc =
            if i <= 0 || i < n - k then
                acc

            else
                let
                    s =
                        next seed

                    j =
                        partner i s

                    swapped =
                        d |> Dict.insert i (at d j) |> Dict.insert j (at d i)
                in
                go (i - 1) s swapped (at swapped i :: acc)
    in
    go (n - 1) 1 Dict.empty []


bench : Int -> Bool
bench n =
    let
        shuffled =
            shuffle n

        k =
            min 100 (n - 1)

        lastK =
            List.drop (n - k) (Array.toList shuffled)
    in
    List.sort (Array.toList shuffled) == List.range 0 (n - 1) && lastK == replay n k
