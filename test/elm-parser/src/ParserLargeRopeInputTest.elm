module ParserLargeRopeInputTest exposing (main)

{-| PARSE-01 (plans/kernel-lib-bug-fixes.md): the parser kernels must read a source String that
is a rope or a slice longer than `string_flatten_limit` (131,072 UTF-16 units).

Each source is built at run time with `++`, which always makes a rope above the limit, and the
repeat count comes from `List.length (List.range 1 n)` so no constant folding can turn it into a
flat literal. One parser per kernel primitive runs on it: `chompWhile` (isSubChar), `symbol`
(isSubString) and `chompUntil` (findSubString), on an ASCII rope, a rope with UTF-16 leaves and
a slice of the ASCII rope.

Failed before the fix: `parserFlatten` called `StringOps::ensureFlat`, which leaves a rope or slice above
the limit as it is, and `parserView` handed it to `flatStringView` (the tag assert aborts in an
assert build; a release build reads garbage). Expected values are Elm's (checked once with stock
elm on node) and are plain arithmetic.
-}

-- CHECK: rope chompWhile: Ok 140000
-- CHECK: rope chompUntil: Ok 140000
-- CHECK: wide rope chompWhile: Ok 140000
-- CHECK: slice chompWhile: Ok 139999

import Html exposing (text)
import Parser exposing ((|.), (|=), Parser)


count : Int
count =
    List.length (List.range 1 70000)


big : String
big =
    String.repeat count "ab" ++ "x"


wide : String
wide =
    String.repeat count "\u{00E9}b" ++ "x"


sliced : String
sliced =
    String.dropLeft 1 big


notX : Char -> Bool
notX c =
    c /= 'x'


whileThenX : Parser Int
whileThenX =
    Parser.succeed identity
        |= (Parser.chompWhile notX |> Parser.getChompedString |> Parser.map String.length)
        |. Parser.symbol "x"
        |. Parser.end


untilX : Parser Int
untilX =
    Parser.succeed identity
        |. Parser.chompUntil "x"
        |= Parser.getOffset


main =
    let
        _ = Debug.log "rope chompWhile" (Parser.run whileThenX big)
        _ = Debug.log "rope chompUntil" (Parser.run untilX big)
        _ = Debug.log "wide rope chompWhile" (Parser.run whileThenX wide)
        _ = Debug.log "slice chompWhile" (Parser.run whileThenX sliced)
    in
    text "done"
