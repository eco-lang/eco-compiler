module ParserIssue9DeadEndsToStringTodoTest exposing (main)

{-| `Parser.deadEndsToString` is a placeholder that returns "TODO deadEndsToString".

<https://github.com/elm/parser/issues/9>

Elm 0.19.1 (elm/parser 1.1.0) returns the literal text "TODO deadEndsToString" for any dead ends.
The function is documented as turning dead ends into a string describing the problem.

-}

-- CHECK: message:
-- CHECK-NOT: TODO deadEndsToString

import Html exposing (text)
import Parser


main =
    let
        _ =
            case Parser.run Parser.int "abc" of
                Ok _ ->
                    Debug.log "message" "unexpected success"

                Err deadEnds ->
                    Debug.log "message" (Parser.deadEndsToString deadEnds)
    in
    text "done"
