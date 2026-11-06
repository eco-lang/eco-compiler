module CoreIssue1001CharToUpperSharpSTest exposing (main)

{-| `Char.toUpper 'ß'` returns a `Char` holding two characters, "SS".

<https://github.com/elm/core/issues/1001>

Elm 0.19.1 returns `'SS'`, so `String.fromChar` of that Char has length 2. A `Char` is a single
character, so the result must have length 1 (whatever character it is).

-}

-- CHECK: length: 1

import Html exposing (text)


main =
    let
        _ =
            Debug.log "length" (String.length (String.fromChar (Char.toUpper 'ß')))
    in
    text "done"
