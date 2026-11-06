module DictUnionDiffIterTest exposing (main)

{-| `Dict.union` and `Dict.diff` on two disjoint `Dict Int Int` values give the expected sizes when repeated 50 times.

`left` holds keys 1 to 100 and `right` keys 101 to 200. On each iteration the test checks that their union has 200 entries and that removing `right`'s keys from the union leaves 100. The logged `True` means every iteration passed.
-}

-- CHECK: done: True

import Dict exposing (Dict)
import Html exposing (text)


build : Int -> Int -> Dict Int Int -> Dict Int Int
build lo hi acc =
    if lo > hi then
        acc

    else
        build (lo + 1) hi (Dict.insert lo (lo * 10) acc)


loop : Dict Int Int -> Dict Int Int -> Int -> Bool -> Bool
loop left right count ok =
    if count <= 0 then
        ok

    else
        let
            merged =
                Dict.union left right

            diffed =
                Dict.diff merged right
        in
        loop left right
            (count - 1)
            (ok && Dict.size merged == 200 && Dict.size diffed == 100)


main =
    let
        left =
            build 1 100 Dict.empty

        right =
            build 101 200 Dict.empty

        _ =
            Debug.log "done" (loop left right 50 True)
    in
    text "done"
