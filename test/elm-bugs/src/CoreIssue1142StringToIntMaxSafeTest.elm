module CoreIssue1142StringToIntMaxSafeTest exposing (main)

{-| `String.toInt` is off by one for integers near 2^53.

<https://github.com/elm/core/issues/1142>

Elm 0.19.1 computes `10 * total + code - 0x30`, which rounds before subtracting, so
`String.toInt "9007199254740991"` is `Just 9007199254740992`. Both inputs below are exactly
representable (within the JavaScript safe-integer range) and must round-trip.

-}

-- CHECK: max safe: Just 9007199254740991
-- CHECK: near max: Just 9007199254740945

import Html exposing (text)


main =
    let
        _ =
            Debug.log "max safe" (String.toInt "9007199254740991")

        _ =
            Debug.log "near max" (String.toInt "9007199254740945")
    in
    text "done"
