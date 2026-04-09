module EmbeddedNilFoldTest exposing (main)

{-| Test empty lists flowing through List.foldl with List.length.
-}

-- CHECK: lengths: [0, 3, 0, 1]

import Html exposing (text)


main =
    let
        lists =
            [ [], [ 1, 2, 3 ], [], [ 42 ] ]

        lengths =
            List.map List.length lists

        _ = Debug.log "lengths" lengths
    in
    text "done"
