module StringFromNumberCaptureTest exposing (main)

{-| `String.fromInt` and `String.fromFloat` work when passed unapplied, as the function
argument of `List.map`.

`[1, 2, 3]` becomes `["1","2","3"]`, and `[0.5, 1.5, 2.5]` becomes `["0.5","1.5","2.5"]`.
-}

-- CHECK: int_strings: ["1","2","3"]
-- CHECK: float_strings: ["0.5","1.5","2.5"]


import Html exposing (text)


main =
    let
        ints : List Int
        ints =
            [ 1, 2, 3 ]

        floats : List Float
        floats =
            [ 0.5, 1.5, 2.5 ]

        _ =
            Debug.log "int_strings" (List.map String.fromInt ints)

        _ =
            Debug.log "float_strings" (List.map String.fromFloat floats)
    in
    text "done"
