module DictOps exposing (bench)

{-| Balanced-tree build, lookup and fold: allocation and key comparison.
-}

import Dict exposing (Dict)


build : Int -> Dict Int Int -> Dict Int Int
build i d =
    if i <= 0 then
        d

    else
        build (i - 1) (Dict.insert i (modBy 9973 (i * 7)) d)


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


bench : Int -> Int
bench n =
    let
        d =
            build n Dict.empty

        s =
            Dict.foldl (\_ v a -> modBy 1000000007 (a + v)) 0 d
    in
    lookups n d s
