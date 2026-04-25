module DictFoldRebuild exposing (main)

-- CHECK: roundtrip: True

import Dict exposing (Dict)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 2


buildDict : Int -> Dict Int Int -> Dict Int Int
buildDict i acc =
    if i <= 0 then
        acc
    else
        buildDict (i - 1) (Dict.insert i i acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


rebuildWithTransform : Dict Int Int -> Dict Int Int
rebuildWithTransform d =
    Dict.foldl (\k v acc -> Dict.insert k (-v) acc) Dict.empty d


main =
    let
        original =
            buildDict m Dict.empty

        transformed =
            applyNTimes loopCount rebuildWithTransform original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
