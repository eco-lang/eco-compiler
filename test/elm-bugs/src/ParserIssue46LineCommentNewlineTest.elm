module ParserIssue46LineCommentNewlineTest exposing (main)

{-| `lineComment` counts the ending newline in the row but leaves it in the input, so the newline
is counted twice.

<https://github.com/elm/parser/issues/46>

On "-- hi\nx", `lineComment "--"` followed by `spaces` and `getPosition` gives `(3,1)` in Elm
0.19.1 (elm/parser 1.1.0): `lineComment` moves the row past the newline without consuming it, and
`spaces` then counts it again. `x` is on row 2, column 1.

-}

-- CHECK: position: Ok (2,1)

import Html exposing (text)
import Parser exposing ((|.), (|=))


main =
    let
        p =
            Parser.succeed identity
                |. Parser.lineComment "--"
                |. Parser.spaces
                |= Parser.getPosition

        _ =
            Debug.log "position" (Parser.run p "-- hi\nx")
    in
    text "done"
