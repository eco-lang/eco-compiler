module DictOps exposing (bench)

{-| Balanced-tree build, lookup and fold: allocation and key comparison. Checked against the
same sums computed directly from the keys, without a `Dict`.
-}

import Dict exposing (Dict)


build : Int -> Dict Int Int -> Dict Int Int
build i d =
    if i <= 0 then
        d

    else
        build (i - 1) (Dict.insert i (value i) d)


lookups : Int -> Dict Int Int -> Int -> Int
lookups i d acc =
    if i <= 0 then
        acc

    else
        case Dict.get (modBy 100000 (i * 31) + 1) d of
            Just v ->
                lookups (i - 1) d (modBy 1000000007 (acc + v))

            Nothing ->
                lookups (i - 1) d acc


value : Int -> Int
value k =
    modBy 9973 (k * 7)


{-| What `lookups` adds up: every key that was inserted, then every looked-up key in `1 .. n`.
-}
expected : Int -> Int
expected n =
    let
        values k acc =
            if k <= 0 then
                acc

            else
                values (k - 1) (modBy 1000000007 (acc + value k))

        found i acc =
            if i <= 0 then
                acc

            else
                let
                    key =
                        modBy 100000 (i * 31) + 1
                in
                if key <= n then
                    found (i - 1) (modBy 1000000007 (acc + value key))

                else
                    found (i - 1) acc
    in
    found n (values n 0)


bench : Int -> Bool
bench n =
    let
        d =
            build n Dict.empty

        s =
            Dict.foldl (\_ v a -> modBy 1000000007 (a + v)) 0 d
    in
    lookups n d s == expected n
