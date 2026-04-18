module ListSort exposing (main)

-- CHECK: result: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loop : List Int -> Int -> Bool -> Bool
loop sorted count ok =
    if count <= 0 then
        ok
    else
        let
            reversed =
                List.reverse sorted

            reSorted =
                List.sort reversed
        in
        loop reSorted (count - 1) (ok && reSorted == sorted)


main =
    let
        sorted =
            List.range 1 m

        result =
            loop sorted n True

        _ =
            Debug.log "result" result
    in
    text "done"
