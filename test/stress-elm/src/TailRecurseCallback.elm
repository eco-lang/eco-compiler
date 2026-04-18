module TailRecurseCallback exposing (main)

-- CHECK: result: 1000000

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loop : (Int -> Int) -> Int -> Int -> Int
loop f count acc =
    if count <= 0 then
        acc
    else
        loop f (count - 1) (f acc)


main =
    let
        increment x =
            x + 1

        result =
            loop increment (n * m) 0

        _ =
            Debug.log "result" result
    in
    text "done"
