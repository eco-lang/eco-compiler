module EmbeddedNilFoldTest exposing (main)

{-| `List.map List.length` over a list of lists, two of them empty, gives 0 for
each empty list.
-}

-- CHECK: lengths: [0,3,0,1]

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
