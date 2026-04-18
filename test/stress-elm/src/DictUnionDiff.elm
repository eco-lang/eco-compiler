module DictUnionDiff exposing (main)

-- CHECK: result: True

import Dict exposing (Dict)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


half : Int
half =
    m // 2


buildDict : Int -> Int -> Dict Int Int -> Dict Int Int
buildDict lo hi acc =
    if lo > hi then
        acc
    else
        buildDict (lo + 1) hi (Dict.insert lo (lo * 10) acc)


loop : Dict Int Int -> Dict Int Int -> Int -> Bool -> Bool
loop left right count ok =
    if count <= 0 then
        ok
    else
        let
            merged =
                Dict.union left right

            mergedSize =
                Dict.size merged

            diffed =
                Dict.diff merged right

            diffedSize =
                Dict.size diffed
        in
        loop left right (count - 1) (ok && mergedSize == m && diffedSize == half)


main =
    let
        left =
            buildDict 1 half Dict.empty

        right =
            buildDict (half + 1) m Dict.empty

        result =
            loop left right n True

        _ =
            Debug.log "result" result
    in
    text "done"
