module ParserLoneLowSurrogateTest exposing (main)

{-| PARSE-04 (plans/kernel-lib-bug-fixes.md): `Parser.chompIf` on a source that starts with two
low surrogates (U+DC00 U+DC01). Elm's JS takes `substr(offset, 2)` as the Char, whose
`Char.toCode` is the first unit, 0xDC00, and advances 2 units.

Failed natively before the fix: `isSubChar` paired any surrogate (its `isHighSurrogate` tested
0xD800-0xDFFF) with a following low surrogate, so the predicate saw the made-up code point 0x110001. Only Int
code points are compared, never Chars. Expectations recorded from Elm on node
(run-js-e2e.js --record).
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
