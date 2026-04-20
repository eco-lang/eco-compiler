module ParserOneOfTest exposing (main)

-- CHECK: true_: Ok True
-- CHECK: false_: Ok False

import Html exposing (text)
import Parser


boolP : Parser.Parser Bool
boolP =
    Parser.oneOf
        [ Parser.map (\_ -> True) (Parser.keyword "true")
        , Parser.map (\_ -> False) (Parser.keyword "false")
        ]


main =
    let
        t = Parser.run boolP "true"
        _ = Debug.log "true_" t
        f = Parser.run boolP "false"
        _ = Debug.log "false_" f
    in
    text "done"
