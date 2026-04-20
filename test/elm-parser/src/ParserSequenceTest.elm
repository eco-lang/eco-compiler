module ParserSequenceTest exposing (main)

-- CHECK: items: Ok [1, 2, 3]
-- CHECK: trailing_ok: Ok [1, 2]

import Html exposing (text)
import Parser exposing (Trailing(..))


intList : Parser.Parser (List Int)
intList =
    Parser.sequence
        { start = "["
        , separator = ","
        , end = "]"
        , spaces = Parser.spaces
        , item = Parser.int
        , trailing = Forbidden
        }


intListTrailing : Parser.Parser (List Int)
intListTrailing =
    Parser.sequence
        { start = "["
        , separator = ","
        , end = "]"
        , spaces = Parser.spaces
        , item = Parser.int
        , trailing = Optional
        }


main =
    let
        r1 = Parser.run intList "[1, 2, 3]"
        _ = Debug.log "items" r1
        r2 = Parser.run intListTrailing "[1,2,]"
        _ = Debug.log "trailing_ok" r2
    in
    text "done"
