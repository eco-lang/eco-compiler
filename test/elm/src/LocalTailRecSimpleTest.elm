module LocalTailRecSimpleTest exposing (main)

{-| Test a simple local tail-recursive function (MonoTailDef in a let binding).
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
