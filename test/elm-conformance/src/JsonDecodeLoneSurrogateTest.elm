module JsonDecodeLoneSurrogateTest exposing (main)

{-| `Json.Decode.string` accepts a `\uXXXX` escape for a lone UTF-16 surrogate and keeps it as one
code unit, while an escaped surrogate pair becomes one character.

Most rows log the decoded string as `Json.Encode` writes it (`shown`), which keeps the output
ASCII by writing a lone surrogate as a `\udxxx` escape, followed by its `String.length` in UTF-16
code units.

  - `lone high`, `lone low`: a single high or low surrogate escape decodes to one unit.
  - `low then high`, `two highs`: surrogates in the wrong order or unpaired stay separate units.
  - `pair`: `\ud83d\ude00` decodes to the emoji U+1F600, two units long.
  - `escaped backslash`: `\\ud83d` is a backslash followed by the text `ud83d`, six units.
  - `marker char`: a lone high surrogate between an escaped and a literal U+FDD0 decodes to
    exactly those three units.
  - `key`: a lone surrogate in an object key, read with `keyValuePairs`, is kept.
  - `in list`: lone surrogates in strings inside a list are kept.
  - `bad after lone`: a lone-surrogate string followed by extra text is still rejected.
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


{-| Returns `s` as `Json.Encode` writes it, with each lone surrogate as a `\udxxx` escape.
-}
shown : String -> String
shown s =
    E.encode 0 (E.string s)


{-| Decodes `text` with `Json.Decode.string` and returns the result as `shown`, with its length.
-}
str : String -> String
str text =
    case D.decodeString D.string text of
        Ok s ->
            "Ok " ++ shown s ++ " len " ++ String.fromInt (String.length s)

        Err _ ->
            "Err"


{-| Like `str`, but reports whether the decoded string equals `expected` instead of showing it.
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
