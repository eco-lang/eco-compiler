module ParserSpacesTest exposing (main)

{-| Checks that `Parser.spaces` skips whitespace around a value: `"   42   "` gives `Ok 42`.
-}

-- CHECK: result: Ok 42

import Html exposing (text)
import Parser exposing ((|.), (|=))


p : Parser.Parser Int
p =
    Parser.succeed identity
        |. Parser.spaces
        |= Parser.int
        |. Parser.spaces


main =
    let
        result = Parser.run p "   42   "
        _ = Debug.log "result" result
    in
    text "done"
