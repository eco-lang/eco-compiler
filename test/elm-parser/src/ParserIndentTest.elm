module ParserIndentTest exposing (main)

{-| Checks that `Parser.getIndent` inside `Parser.withIndent 4` returns 4.

The parser runs on an empty string and consumes nothing, so the result is
`Ok 4` without any input being read.
-}

-- CHECK: indent: Ok 4

import Html exposing (text)
import Parser


p : Parser.Parser Int
p =
    Parser.withIndent 4 Parser.getIndent


main =
    let
        result = Parser.run p ""
        _ = Debug.log "indent" result
    in
    text "done"
