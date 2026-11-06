module ParserChompUntilEndOrTest exposing (main)

{-| `Parser.chompUntilEndOr` chomps to the end of the input when the closing string never appears.

The closing string is `"}"` and the input `"abc"` has none, so
`getChompedString` returns `Ok "abc"`.

Among what is not tested: input that does contain the closing string.
-}

-- CHECK: chomped: Ok "abc"

import Html exposing (text)
import Parser


main =
    let
        p = Parser.getChompedString (Parser.chompUntilEndOr "}")
        result = Parser.run p "abc"
        _ = Debug.log "chomped" result
    in
    text "done"
