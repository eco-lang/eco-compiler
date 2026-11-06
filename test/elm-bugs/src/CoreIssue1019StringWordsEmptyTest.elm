module CoreIssue1019StringWordsEmptyTest exposing (main)

{-| `String.words` of a string with no words returns `[]`.

<https://github.com/elm/core/issues/1019>

The test tries the empty string and three strings of only whitespace (spaces; spaces and a
newline; a tab, newline, carriage return and space). Elm 0.19.1 returns `[""]` for each.

-}

-- CHECK: words empty: []
-- CHECK: words blank: []
-- CHECK: words spaces: []
-- CHECK: words tab newline return: []

import Html exposing (text)


main =
    let
        _ =
            Debug.log "words empty" (String.words "")

        _ =
            Debug.log "words blank" (String.words "  \n ")

        _ =
            Debug.log "words spaces" (String.words "   ")

        _ =
            Debug.log "words tab newline return" (String.words "\t\n\u{000D} ")
    in
    text "done"
