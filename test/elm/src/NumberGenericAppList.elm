module NumberGenericAppList exposing (main)

{-| A number literal passed through a generic function, here `List.head`
followed by `Maybe.withDefault 0`, keeps the type `number`, so the
`let`-bound result can be used in `Float` arithmetic: `round (1.5 * n)` logs
45.
-}

-- CHECK: numgenapp: 45

import Html exposing (text)


main =
    let
        n =
            Maybe.withDefault 0 (List.head [ 30 ])

        _ =
            Debug.log "numgenapp" (round (1.5 * n))
    in
    text "done"
