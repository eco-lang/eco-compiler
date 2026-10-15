module StringFromFloatJsFormatTest exposing (main)

{-| `String.fromFloat` must write numbers as JavaScript does (ECMAScript Number::toString):
plain digits from 1e-7 up to 1e21, exponent form outside that range. The native kernel used to
pick whichever of fixed or scientific notation was shorter ("1e+09" for 1e9), which made the
self-hosted compiler emit the JS literal `1e+09.0`. The values go through `List.map` so the
runtime formats them, not a compile-time fold.
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
