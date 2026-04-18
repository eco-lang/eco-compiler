module ListIntersperse exposing (main)

-- CHECK: result: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loop : List Int -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            interspersed =
                List.intersperse 0 original

            len =
                List.length interspersed

            expectedLen =
                m * 2 - 1

            filtered =
                List.filter (\x -> x /= 0) interspersed
        in
        loop original (count - 1) (ok && len == expectedLen && filtered == original)


main =
    let
        original =
            List.range 1 m

        result =
            loop original n True

        _ =
            Debug.log "result" result
    in
    text "done"
