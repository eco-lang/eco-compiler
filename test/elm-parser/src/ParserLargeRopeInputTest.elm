module ParserLargeRopeInputTest exposing (main)

{-| Checks that `chompWhile`, `symbol`, `chompUntil` and `getOffset` work on long strings built at run time.

Each input is about 140,000 characters, made by `String.repeat` and `++` at run
time, with a repeat count computed from `List.length (List.range 1 70000)`.
`big` is 70,000 copies of `"ab"` followed by `"x"`; `wide` uses `"\u{00E9}b"`
instead of `"ab"`; `sliced` is `big` without its first character.

  - `whileThenX` chomps up to the `x`, then requires the `x` and the end of
    input, and returns the chomped length: 140,000 for `big` and `wide`,
    139,999 for `sliced`. `é` counts as one character in `String.length`.
  - `untilX` runs `chompUntil "x"` on `big` and returns the offset, 140,000.

-}

-- CHECK: rope chompWhile: Ok 140000
-- CHECK: rope chompUntil: Ok 140000
-- CHECK: wide rope chompWhile: Ok 140000
-- CHECK: slice chompWhile: Ok 139999

import Html exposing (text)
import Parser exposing ((|.), (|=), Parser)


{-| The repeat count, 70,000, computed at run time rather than written as a literal.
-}
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
