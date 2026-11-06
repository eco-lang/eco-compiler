module LetNumberFracRecordTest exposing (main)

{-| The two `number` fields of a let-bound record literal are typed
independently, one used as an `Int` and the other as a `Float`.

`r = { intPart = 30, fracPart = 40 }` has type
`{ intPart : number, fracPart : number1 }`. `toFloat r.intPart` makes `intPart`
an `Int` and `0.1 * r.fracPart` makes `fracPart` a `Float`, so the result is
30 + 4 and the test logs 34.

-}

-- CHECK: frac: 34

import Html exposing (text)


main =
    let
        r =
            { intPart = 30, fracPart = 40 }

        result =
            round (toFloat r.intPart + 0.1 * r.fracPart)

        _ =
            Debug.log "frac" result
    in
    text "done"
