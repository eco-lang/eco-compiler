module LocalTailRecSimpleTest exposing (main)

{-| An annotated let-bound tail-recursive function with an accumulator computes
the sum 1 + 2 + ... + 10 = 55.
-}

-- CHECK: result: 55

import Html exposing (text)


main =
    let
        sumUpTo : Int -> Int -> Int
        sumUpTo i s =
            if i <= 0 then
                s
            else
                sumUpTo (i - 1) (s + i)

        result = sumUpTo 10 0
        _ = Debug.log "result" result
    in
    text "done"
