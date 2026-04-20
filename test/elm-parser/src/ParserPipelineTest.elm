module ParserPipelineTest exposing (main)

-- CHECK: point: Ok { x = 3, y = 4 }

import Html exposing (text)
import Parser exposing ((|.), (|=))


type alias Point =
    { x : Int, y : Int }


point : Parser.Parser Point
point =
    Parser.succeed Point
        |. Parser.symbol "("
        |= Parser.int
        |. Parser.symbol ","
        |= Parser.int
        |. Parser.symbol ")"


main =
    let
        result = Parser.run point "(3,4)"
        _ = Debug.log "point" result
    in
    text "done"
