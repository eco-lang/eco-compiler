module EmbeddedNothingMapTest exposing (main)

{-| `List.map` with a function that matches `Maybe` maps each `Nothing` to -1 and
each `Just` to its payload.
-}

-- CHECK: results: [-1,1,-1,2]

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
