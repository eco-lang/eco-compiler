module StringBuildChunk exposing (main)

-- CHECK: result: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildString : Int -> String -> String
buildString i acc =
    if i <= 0 then
        acc
    else
        buildString (i - 1) (acc ++ "abcd")


loop : Int -> Bool -> Bool
loop count ok =
    if count <= 0 then
        ok
    else
        let
            s =
                buildString m ""

            len =
                String.length s
        in
        loop (count - 1) (ok && len == m * 4)


main =
    let
        result =
            loop n True

        _ =
            Debug.log "result" result
    in
    text "done"
