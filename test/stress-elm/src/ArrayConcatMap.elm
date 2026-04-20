module ArrayConcatMap exposing (main)

-- CHECK: result: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


concatMap : (a -> Array b) -> Array a -> Array b
concatMap f arr =
    Array.foldl (\x acc -> Array.append acc (f x)) Array.empty arr


loop : Int -> Bool -> Bool
loop count ok =
    if count <= 0 then
        ok
    else
        let
            original =
                Array.initialize m (\i -> i + 1)

            expanded =
                concatMap (\x -> Array.fromList [ x, x + m, x + m * 2 ]) original

            len =
                Array.length expanded
        in
        loop (count - 1) (ok && len == m * 3)


main =
    let
        result =
            loop n True

        _ =
            Debug.log "result" result
    in
    text "done"
