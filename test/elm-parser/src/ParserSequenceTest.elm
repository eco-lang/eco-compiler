module ParserSequenceTest exposing (main)

{-| Checks `Parser.sequence` with forbidden and with optional trailing separators.

With `Forbidden`, `"[1, 2, 3]"` (spaces after the commas) gives
`Ok [1,2,3]`. With `Optional`, `"[1,2,]"` gives `Ok [1,2]`.

Among what is not tested: rejection of a trailing separator under `Forbidden`,
and the `Mandatory` setting.
-}

-- CHECK: items: Ok [1,2,3]
-- CHECK: trailing_ok: Ok [1,2]

import Html exposing (text)
import Parser exposing (Trailing(..))


intList : Parser.Parser (List Int)
intList =
    Parser.sequence
        { start = "["
        , separator = ","
        , end = "]"
        , spaces = Parser.spaces
        , item = Parser.int
        , trailing = Forbidden
        }


intListTrailing : Parser.Parser (List Int)
intListTrailing =
    Parser.sequence
        { start = "["
        , separator = ","
        , end = "]"
        , spaces = Parser.spaces
        , item = Parser.int
        , trailing = Optional
        }


main =
    let
        r1 = Parser.run intList "[1, 2, 3]"
        _ = Debug.log "items" r1
        r2 = Parser.run intListTrailing "[1,2,]"
        _ = Debug.log "trailing_ok" r2
    in
    text "done"
