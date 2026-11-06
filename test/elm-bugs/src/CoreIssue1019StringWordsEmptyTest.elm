module CoreIssue1019StringWordsEmptyTest exposing (main)

{-| `String.words` of an empty or blank string returns `[""]`.

<https://github.com/elm/core/issues/1019>

Elm 0.19.1 returns `[""]` (JavaScript's `split` always returns one piece). A string with no words
has no words: the result must be `[]`.

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
