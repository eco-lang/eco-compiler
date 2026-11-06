module StringFromFloatJsFormatTest exposing (main)

{-| `String.fromFloat` writes numbers as JavaScript's `Number.prototype.toString` does:
plain digits for magnitudes from 1e-6 up to but not including 1e21, and exponent form
(`1e+21`, `1.5e+300`, `1e-7`, `1.25e-7`) outside that range.

The ten values are converted with `List.map String.fromFloat` and joined with commas, so
one line checks them all. Among them, 1e9 must print as `1000000000` rather than `1e+09`,
and a value with a fractional part, `123456789.125`, keeps every digit.
-}

-- CHECK: formatted: "1000000000,-1000000000,100000000000000000000,1e+21,1.5e+300,0.000001,1e-7,1.25e-7,123456789.125,0.1"


import Html exposing (text)


main =
    let
        _ =
            Debug.log "formatted"
                ([ 1.0e9, -1.0e9, 1.0e20, 1.0e21, 1.5e300, 0.000001, 1.0e-7, 1.25e-7, 123456789.125, 0.1 ]
                    |> List.map String.fromFloat
                    |> String.join ","
                )
    in
    text "done"
