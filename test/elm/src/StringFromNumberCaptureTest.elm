module StringFromNumberCaptureTest exposing (main)

{-| Higher-order capture of `String.fromInt` / `String.fromFloat` via
    `List.map`. Forces a closure-call into the migrated `_Int` / `_Float`
    variants.
-}

-- CHECK: int_strings: ["1", "2", "3"]
-- CHECK: float_strings: ["0.5", "1.5", "2.5"]


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
