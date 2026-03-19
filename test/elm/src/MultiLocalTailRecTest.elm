module MultiLocalTailRecTest exposing (main)

{-| Test multiple local tail-recursive defs in same let block. -}

-- CHECK: result: 15

import Html exposing (text)


main =
    let
        countDown i =
            if i <= 0 then
                0

            else
                countDown (i - 1)

        sumUp i acc =
            if i <= 0 then
                acc

            else
                sumUp (i - 1) (acc + i)

        _ =
            Debug.log "result" (countDown 5 + sumUp 5 0)
    in
    text "done"
