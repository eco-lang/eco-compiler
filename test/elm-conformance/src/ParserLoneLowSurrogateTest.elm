module ParserLoneLowSurrogateTest exposing (main)

{-| `Parser.chompIf` on a string that starts with two low surrogates (U+DC00 U+DC01) hands its
predicate a `Char` whose code is 0xDC00 and consumes two UTF-16 code units.

The string is built with `Char.fromCode`. One predicate checks for the code 0xDC00, one for a
code above 0x10FFFF, which must never be seen, and the third test logs the length of the chomped
text.

-}

-- CHECK: code is DC00: "Ok"
-- CHECK: code above 10FFFF: "Err"
-- CHECK: chomped length: "Ok 2"

import ConformanceHelp exposing (logAll, worker)
import Parser exposing (Parser)


src : String
src =
    String.fromList [ Char.fromCode 0xDC00, Char.fromCode 0xDC01 ]


okErr : Result x a -> String
okErr r =
    case r of
        Ok _ ->
            "Ok"

        Err _ ->
            "Err"


lenResult : Result x Int -> String
lenResult r =
    case r of
        Ok n ->
            "Ok " ++ String.fromInt n

        Err _ ->
            "Err"


chompedLength : Parser Int
chompedLength =
    Parser.getChompedString (Parser.chompIf (\_ -> True))
        |> Parser.map String.length


report : ()
report =
    logAll
        [ ( "code is DC00", okErr (Parser.run (Parser.chompIf (\c -> Char.toCode c == 0xDC00)) src) )
        , ( "code above 10FFFF", okErr (Parser.run (Parser.chompIf (\c -> Char.toCode c > 0x0010FFFF)) src) )
        , ( "chomped length", lenResult (Parser.run chompedLength src) )
        ]


main : Program () () ()
main =
    worker report
