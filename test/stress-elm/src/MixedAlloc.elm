module MixedAlloc exposing (main)

-- CHECK: result: True

import Dict exposing (Dict)
import Html exposing (text)
import Set exposing (Set)


n : Int
n =
    1000


m : Int
m =
    1000


quarter : Int
quarter =
    m // 4


buildDict : Int -> Dict Int Int -> Dict Int Int
buildDict i acc =
    if i <= 0 then
        acc
    else
        buildDict (i - 1) (Dict.insert i (i * 3) acc)


buildClosures : Int -> List (Int -> Int) -> List (Int -> Int)
buildClosures i acc =
    if i <= 0 then
        acc
    else
        buildClosures (i - 1) ((\k x -> x + k) i :: acc)


foldClosures : List (Int -> Int) -> Int -> Int
foldClosures fns acc =
    case fns of
        [] ->
            acc

        f :: rest ->
            foldClosures rest (f acc)


loop : Int -> Bool -> Bool
loop count ok =
    if count <= 0 then
        ok
    else
        let
            -- Build a Dict of quarter entries, fold to sum
            dict =
                buildDict quarter Dict.empty

            dictSum =
                Dict.foldl (\_ v acc -> acc + v) 0 dict

            -- Build a List of quarter elements, fold to sum
            list =
                List.range 1 quarter

            listSum =
                List.foldl (+) 0 list

            -- Build a Set of quarter elements, fold to sum
            set =
                Set.fromList (List.range 1 quarter)

            setSum =
                Set.foldl (+) 0 set

            -- Build quarter closures, apply all
            closures =
                buildClosures quarter []

            closureSum =
                foldClosures closures 0

            -- All sums should be deterministic
            expectedListSum =
                quarter * (quarter + 1) // 2

            expectedDictSum =
                expectedListSum * 3
        in
        loop (count - 1)
            (ok
                && dictSum
                == expectedDictSum
                && listSum
                == expectedListSum
                && setSum
                == expectedListSum
                && closureSum
                == expectedListSum
            )


main =
    let
        result =
            loop n True

        _ =
            Debug.log "result" result
    in
    text "done"
