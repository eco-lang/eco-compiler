module LetNumberListConsHeadTest exposing (main)

{-| The head of a list of `number` literals, matched by a `::` pattern in a
`case` and multiplied by a `Float`, is a `Float`.

`case [ 30, 40 ] of h :: _ -> round (h * 1.5)` logs 45.

-}

-- CHECK: listcons: 45

import Html exposing (text)


main =
    let
        result =
            case [ 30, 40 ] of
                h :: _ ->
                    round (h * 1.5)

                _ ->
                    0

        _ =
            Debug.log "listcons" result
    in
    text "done"
