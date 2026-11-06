module ParserIssue53ChompUntilOffsetPositionTest exposing (main)

{-| `chompUntil` leaves the parser's offset and its row/column out of sync.

<https://github.com/elm/parser/issues/53>

`Elm.Kernel.Parser.findSubString` returns the offset of the start of the searched string but the
row and column after its end. After `chompUntil "bar"` on "foobar" (one line, so column = offset
+ 1), Elm 0.19.1 (elm/parser 1.1.0) reports offset 3 and column 7. They must agree: (3,4) or
(6,7).

-}

-- CHECK: {{(^|\n)offset and column: Ok \((3,4|6,7)\)(\n|$)}}

import Html exposing (text)
import Parser exposing ((|.), (|=))


main =
    let
        p =
            Parser.succeed Tuple.pair
                |. Parser.chompUntil "bar"
                |= Parser.getOffset
                |= Parser.getCol

        _ =
            Debug.log "offset and column" (Parser.run p "foobar")
    in
    text "done"
