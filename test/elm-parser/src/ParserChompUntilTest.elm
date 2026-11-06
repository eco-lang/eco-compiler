module ParserChompUntilTest exposing (main)

{-| `Parser.chompUntil` chomps up to the first occurrence of a string and leaves that string unchomped.

Chomping until `"end"` in `"abc end xyz"` gives `Ok "abc "` from
`getChompedString`: the space before `"end"` is included and `"end"` is not.

Among what is not tested: input where the string never appears, which is an
error.
-}

-- CHECK: until: Ok "abc "

import Html exposing (text)
import Parser


main =
    let
        p = Parser.getChompedString (Parser.chompUntil "end")
        result = Parser.run p "abc end xyz"
        _ = Debug.log "until" result
    in
    text "done"
