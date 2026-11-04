module JsonDecodeLoneSurrogateTest exposing (main)

{-| JSON-NEW-2 (follow-up of JSON-01, plans/kernel-lib-bug-fixes.md): `Json.Decode` of JSON text
holding a lone-surrogate `\uXXXX` escape. Elm (JSON.parse) accepts it and keeps the lone
surrogate as one UTF-16 unit, in a string value or an object key; a valid escaped pair is one
code point. eco parsed with the nlohmann lexer, which rejects a lone-surrogate escape, so every
case here failed with "This is not valid JSON!". eco now hides each lone surrogate from the
lexer (`hideLoneSurrogates`) and restores it in the parsed string.
Expected values recorded from Elm on node. The source and the output stay ASCII: a result is
shown re-encoded with `Json.Encode`, which writes a lone surrogate as `\udxxx`.

-}

-- CHECK: lone high: "Ok \"\\ud83d\" len 1"
-- CHECK: lone low: "Ok \"\\udc00\" len 1"
-- CHECK: low then high: "Ok \"a\\ude00\\ud83db\" len 4"
-- CHECK: two highs: "Ok \"\\ud83d\\ud83d\" len 2"
-- CHECK: pair: "Ok True len 2"
-- CHECK: escaped backslash: "Ok \"\\\\ud83d\" len 6"
-- CHECK: marker char: "Ok True len 3"
-- CHECK: key: "Ok \"\\ud83d\" = 1"
-- CHECK: in list: "Ok [\"\\ud83d\",\"x\",\"\\udc00\"]"
-- CHECK: bad after lone: "Err"

import ConformanceHelp exposing (logAll, worker)
import Json.Decode as D
import Json.Encode as E


emoji : String
emoji =
    String.fromChar (Char.fromCode 0x0001F600)


{-| The String as `Json.Encode` writes it: ASCII, with each lone surrogate as `\udxxx`.
(`String.toList` and `Char.toCode` cannot show a lone surrogate on the JS target.)
-}
shown : String -> String
shown s =
    E.encode 0 (E.string s)


str : String -> String
str text =
    case D.decodeString D.string text of
        Ok s ->
            "Ok " ++ shown s ++ " len " ++ String.fromInt (String.length s)

        Err _ ->
            "Err"


{-| Like `str`, but for a result holding non-ASCII text: compares it with `expected`.
-}
strIs : String -> String -> String
strIs expected text =
    case D.decodeString D.string text of
        Ok s ->
            "Ok " ++ (if s == expected then "True" else "False") ++ " len " ++ String.fromInt (String.length s)

        Err _ ->
            "Err"


report : ()
report =
    logAll
        [ ( "lone high", str "\"\\ud83d\"" )
        , ( "lone low", str "\"\\uDC00\"" )
        , ( "low then high", str "\"a\\ude00\\ud83db\"" )
        , ( "two highs", str "\"\\ud83d\\ud83d\"" )
        , ( "pair", strIs emoji "\"\\ud83d\\ude00\"" )
        , ( "escaped backslash", str "\"\\\\ud83d\"" )
        , ( "marker char", strIs ("\u{FDD0}" ++ String.left 1 emoji ++ "\u{FDD0}") "\"\\ufdd0\\ud83d\u{FDD0}\"" )
        , ( "key"
          , case D.decodeString (D.keyValuePairs D.int) "{\"\\ud83d\":1}" of
                Ok [ ( k, v ) ] ->
                    "Ok " ++ shown k ++ " = " ++ String.fromInt v

                Ok _ ->
                    "Ok ?"

                Err _ ->
                    "Err"
          )
        , ( "in list"
          , case D.decodeString (D.list D.string) "[\"\\ud83d\",\"x\",\"\\udc00\"]" of
                Ok l ->
                    "Ok [" ++ String.join "," (List.map shown l) ++ "]"

                Err _ ->
                    "Err"
          )
        , ( "bad after lone", str "\"\\ud83d\" x" )
        ]


main : Program () () ()
main =
    worker report
