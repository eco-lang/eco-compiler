module ParserChompWhileTest exposing (main)

{-| `Parser.chompWhile` chomps characters while the predicate holds and stops at the first that fails it.

With `Char.isAlpha` on `"abc123"`, `getChompedString` returns `Ok "abc"`. The
run succeeds although `"123"` is left, because nothing requires the end of
input.
-}

-- CHECK: chomped: Ok "abc"

import Char
import Html exposing (text)
import Parser


alphaP : Parser.Parser String
alphaP =
    Parser.getChompedString (Parser.chompWhile Char.isAlpha)


main =
    let
        result = Parser.run alphaP "abc123"
        _ = Debug.log "chomped" result
    in
    text "done"
