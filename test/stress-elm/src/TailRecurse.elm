module TailRecurse exposing (main)

-- CHECK: result: 1000000

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loop : Int -> Int -> Int
loop count acc =
    if count <= 0 then
        acc
    else
        loop (count - 1) (acc + 1)


main =
    let
        result =
            loop (n * m) 0

        _ =
            Debug.log "result" result
    in
    text "done"
