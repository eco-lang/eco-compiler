module ParserLoopTest exposing (main)

-- CHECK: list: Ok [1, 2, 3]

import Html exposing (text)
import List
import Parser exposing ((|.), (|=))


listLoop : Parser.Parser (List Int)
listLoop =
    Parser.succeed identity
        |. Parser.symbol "["
        |= Parser.loop [] helper
        |. Parser.symbol "]"


helper : List Int -> Parser.Parser (Parser.Step (List Int) (List Int))
helper revItems =
    Parser.oneOf
        [ Parser.succeed (\n -> Parser.Loop (n :: revItems))
            |= Parser.int
            |. Parser.oneOf
                [ Parser.symbol ","
                , Parser.succeed ()
                ]
        , Parser.succeed (Parser.Done (List.reverse revItems))
        ]


main =
    let
        result = Parser.run listLoop "[1,2,3]"
        _ = Debug.log "list" result
    in
    text "done"
