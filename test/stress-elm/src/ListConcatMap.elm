module ListConcatMap exposing (main)

-- CHECK: result: True

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


loop : Int -> Bool -> Bool
loop count ok =
    if count <= 0 then
        ok
    else
        let
            original =
                List.range 1 m

            expanded =
                List.concatMap (\x -> [ x, x + m, x + m * 2 ]) original

            len =
                List.length expanded
        in
        loop (count - 1) (ok && len == m * 3)


main =
    let
        result =
            loop loopCount True

        _ =
            Debug.log "result" result
    in
    text "done"
