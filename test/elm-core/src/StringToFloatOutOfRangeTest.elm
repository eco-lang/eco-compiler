module StringToFloatOutOfRangeTest exposing (main)

{-| Checks that `String.toFloat` accepts a well-formed number whose magnitude is outside the range of a finite `Float`: an overflow gives `Infinity` (or `-Infinity`) and an underflow gives `0`.

A number in range, `"1e300"`, is also parsed, as `Just 1e300`.

-}

-- CHECK: overflow: Just Infinity
-- CHECK: negOverflow: Just -Infinity
-- CHECK: underflow: Just 0
-- CHECK: inRange: Just 1e+300

import Html exposing (text)


main =
    let
        _ =
            Debug.log "overflow" (String.toFloat "1e400")

        _ =
            Debug.log "negOverflow" (String.toFloat "-1e400")

        _ =
            Debug.log "underflow" (String.toFloat "1.5e-400")

        _ =
            Debug.log "inRange" (String.toFloat "1e300")
    in
    text "done"
