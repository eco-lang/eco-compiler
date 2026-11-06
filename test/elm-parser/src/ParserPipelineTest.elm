module ParserPipelineTest exposing (main)

{-| Checks that `|=` and `|.` build a record from parsed fields while discarding punctuation.

`point` parses `"(3,4)"` into `Ok { x = 3, y = 4 }` using the `Point` record
constructor.
-}

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
