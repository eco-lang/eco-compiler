module ParserMapChompedStringTest exposing (main)

-- CHECK: result: Ok "abc-ABC"

import Char
import Html exposing (text)
import Parser
import String


upperWithRaw : Parser.Parser String
upperWithRaw =
    Parser.mapChompedString
        (\raw _ -> raw ++ "-" ++ String.toUpper raw)
        (Parser.chompWhile Char.isAlpha)


main =
    let
        result = Parser.run upperWithRaw "abc"
        _ = Debug.log "result" result
    in
    text "done"
