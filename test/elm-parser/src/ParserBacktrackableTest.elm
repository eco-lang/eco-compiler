module ParserBacktrackableTest exposing (main)

-- CHECK: result: Ok 1

import Html exposing (text)
import Parser exposing ((|.))


p : Parser.Parser Int
p =
    Parser.oneOf
        [ Parser.backtrackable (Parser.succeed 0 |. Parser.keyword "letx")
        , Parser.succeed 1 |. Parser.keyword "let"
        ]


main =
    let
        result = Parser.run p "let"
        _ = Debug.log "result" result
    in
    text "done"
