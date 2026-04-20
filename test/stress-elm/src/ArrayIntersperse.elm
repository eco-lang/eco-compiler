module ArrayIntersperse exposing (main)

-- CHECK: result: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


intersperse : a -> Array a -> Array a
intersperse sep arr =
    let
        step x acc =
            if Array.isEmpty acc then
                Array.push x acc
            else
                Array.push x (Array.push sep acc)
    in
    Array.foldl step Array.empty arr


loop : Array Int -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            interspersed =
                intersperse 0 original

            len =
                Array.length interspersed

            expectedLen =
                m * 2 - 1

            filtered =
                Array.filter (\x -> x /= 0) interspersed
        in
        loop original (count - 1) (ok && len == expectedLen && filtered == original)


main =
    let
        original =
            Array.initialize m (\i -> i + 1)

        result =
            loop original n True

        _ =
            Debug.log "result" result
    in
    text "done"
