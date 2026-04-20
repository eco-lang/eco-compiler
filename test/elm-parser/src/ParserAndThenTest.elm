module ParserAndThenTest exposing (main)

-- CHECK: pair: Ok (3, 3)

import Html exposing (text)
import Parser
import String


dependent : Parser.Parser ( Int, Int )
dependent =
    Parser.int
        |> Parser.andThen
            (\n ->
                Parser.getChompedString (Parser.chompWhile (\c -> c == 'a'))
                    |> Parser.map (\s -> ( n, String.length s ))
            )


main =
    let
        result = Parser.run dependent "3aaa"
        _ = Debug.log "pair" result
    in
    text "done"
