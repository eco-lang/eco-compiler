module EmbeddedConstantsInListTest exposing (main)

{-| `List.filterMap identity` on a list mixing `Nothing` and `Just` values keeps
the `Just` payloads in order.
-}

-- CHECK: filtered: [1,2]

import Html exposing (text)


main =
    let
        items =
            [ Nothing, Just 1, Nothing, Just 2, Nothing ]

        filtered =
            List.filterMap identity items

        _ = Debug.log "filtered" filtered
    in
    text "done"
