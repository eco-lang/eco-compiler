module ParserPositionTest exposing (main)

-- CHECK: pos: Ok (1, 4)
-- CHECK: row: Ok 1
-- CHECK: col: Ok 4
-- CHECK: offset: Ok 3
-- CHECK: src: Ok "abcdef"

import Html exposing (text)
import Parser exposing ((|.), (|=))


after3 : Parser.Parser a -> Parser.Parser a
after3 innerP =
    Parser.succeed identity
        |. Parser.chompIf (\_ -> True)
        |. Parser.chompIf (\_ -> True)
        |. Parser.chompIf (\_ -> True)
        |= innerP


main =
    let
        _ = Debug.log "pos" (Parser.run (after3 Parser.getPosition) "abcdef")
        _ = Debug.log "row" (Parser.run (after3 Parser.getRow) "abcdef")
        _ = Debug.log "col" (Parser.run (after3 Parser.getCol) "abcdef")
        _ = Debug.log "offset" (Parser.run (after3 Parser.getOffset) "abcdef")
        _ = Debug.log "src" (Parser.run Parser.getSource "abcdef")
    in
    text "done"
