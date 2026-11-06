module ParserAndThenTest exposing (main)

{-| `Parser.andThen` lets the parser that runs next depend on a value already parsed.

An integer is parsed and then passed to a second parser, which chomps the
`'a'` characters that follow and pairs the integer with how many it chomped.
Run on `"3aaa"`, the result is `Ok (3,3)`.

Among what is not tested: a second parser that actually behaves differently
depending on the value, and failure of either stage.
-}

-- CHECK: pair: Ok (3,3)

import Html exposing (text)
import Parser
import String


{-| Parses an integer followed by a run of `'a'` characters, returning the integer and the length of the run.
-}
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
