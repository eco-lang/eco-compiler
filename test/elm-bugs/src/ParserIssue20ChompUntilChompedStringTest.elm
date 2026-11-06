module ParserIssue20ChompUntilChompedStringTest exposing (main)

{-| After `chompUntil`, the chomped string and the position disagree.

<https://github.com/elm/parser/issues/20>

On "foobar", `getChompedString (chompUntil "bar")` followed by `getPosition` gives
`Ok ("foo",(1,7))` in Elm 0.19.1 (elm/parser 1.1.0): the position is past "bar" but the chomped
string (and the offset) stop before it. Either both include "bar", `("foobar",(1,7))`, or neither
does, `("foo",(1,4))`.

-}

-- CHECK: {{(^|\n)result: Ok \((("foobar",\(1,7\))|("foo",\(1,4\)))\)(\n|$)}}

import Html exposing (text)
import Parser exposing ((|=))


main =
    let
        chomper =
            Parser.succeed Tuple.pair
                |= Parser.getChompedString (Parser.chompUntil "bar")
                |= Parser.getPosition

        _ =
            Debug.log "result" (Parser.run chomper "foobar")
    in
    text "done"
