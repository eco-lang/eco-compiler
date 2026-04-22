module DictUnionDiffIterTest exposing (main)

{-| Repeated `Dict.union` / `Dict.diff` over disjoint dictionaries must
    not crash and must keep returning the expected sizes. Scaled-down
    regression for a SIGSEGV observed in the stress suite
    (DictUnionDiff).
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
