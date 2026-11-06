module CoreIssue1001CharToUpperSharpSTest exposing (main)

{-| `Char.toUpper 'ß'` returns a single character.

<https://github.com/elm/core/issues/1001>

Elm 0.19.1 returns a `Char` holding "SS", so `String.fromChar` of it has length 2. A `Char` is one
character, so the length must be 1, whichever character it is.

-}

-- CHECK: length: 1

import Html exposing (text)


main =
    let
        _ =
            Debug.log "length" (String.length (String.fromChar (Char.toUpper 'ß')))
    in
    text "done"
