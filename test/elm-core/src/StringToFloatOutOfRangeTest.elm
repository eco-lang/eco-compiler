module StringToFloatOutOfRangeTest exposing (main)

{-| Checks that `String.toFloat` accepts a well-formed number whose magnitude is
outside the range of a finite `Float`, as Elm does: an overflow gives
`Infinity` (or `-Infinity`) and an underflow gives `0`.

The native kernel answers `Nothing` for these, so `String.toFloat "1e400"`
differs from Elm. The native-built compiler's float literal parser
(`Compiler.Parse.Number.number`) also reads literals with `String.toFloat`, so a
literal such as `1e400` takes its "rejected float" path there.

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
