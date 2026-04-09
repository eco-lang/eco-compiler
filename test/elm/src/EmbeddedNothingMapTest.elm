module EmbeddedNothingMapTest exposing (main)

{-| Test Nothing flowing through List.map and then pattern-matched.
-}

-- CHECK: results: [-1, 1, -1, 2]

import Html exposing (text)


extract m =
    case m of
        Just x ->
            x

        Nothing ->
            -1


main =
    let
        items =
            [ Nothing, Just 1, Nothing, Just 2 ]

        results =
            List.map extract items

        _ = Debug.log "results" results
    in
    text "done"
