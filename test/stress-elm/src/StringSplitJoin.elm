module StringSplitJoin exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildWords : Int -> List String -> List String
buildWords i acc =
    if i <= 0 then
        acc
    else
        buildWords (i - 1) (String.fromInt i :: acc)


loop : String -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            parts =
                String.words original

            rejoined =
                String.join " " parts
        in
        loop original (count - 1) (ok && rejoined == original)


main =
    let
        words =
            buildWords m []

        original =
            String.join " " words

        result =
            loop original n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
