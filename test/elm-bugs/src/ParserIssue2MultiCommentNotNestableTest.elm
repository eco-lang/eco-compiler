module ParserIssue2MultiCommentNotNestableTest exposing (main)

{-| `multiComment "/*" "*/" NotNestable` does not consume the closing `*/`.

<https://github.com/elm/parser/issues/2>

Elm 0.19.1 (elm/parser 1.1.0) fails `multiComment "/*" "*/" NotNestable |. end` on `"/*abc*/"`
with ExpectingEnd, because the parser's offset stops before `*/` (its row and column do move past
it). `Nestable` mode handles the same input. The whole comment must be consumed.

-}

-- CHECK: notNestable: Ok ()
-- CHECK: nestable: Ok ()

import Html exposing (text)
import Parser exposing ((|.), Nestable(..))


main =
    let
        _ =
            Debug.log "notNestable" (Parser.run (Parser.multiComment "/*" "*/" NotNestable |. Parser.end) "/*abc*/")

        _ =
            Debug.log "nestable" (Parser.run (Parser.multiComment "/*" "*/" Nestable |. Parser.end) "/*abc*/")
    in
    text "done"
