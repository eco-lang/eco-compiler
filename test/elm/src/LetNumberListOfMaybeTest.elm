module LetNumberListOfMaybeTest exposing (main)

{-| `number` literals inside `Just` values in a let-bound list, mapped with a
`Float` multiplication, are `Float`s.

`xs = [ Just 30, Just 40 ]`, and each payload is turned into `round (x * 1.5)`
by `Maybe.map`, with 0 as the default for `Nothing`. The test logs `[45,60]`.

-}

-- CHECK: listmaybe: [45,60]

import Html exposing (text)


main =
    let
        xs =
            [ Just 30, Just 40 ]

        result =
            List.map (\m -> Maybe.withDefault 0 (Maybe.map (\x -> round (x * 1.5)) m)) xs

        _ =
            Debug.log "listmaybe" result
    in
    text "done"
