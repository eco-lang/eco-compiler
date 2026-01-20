module Main exposing (main)

import Html exposing (text)

strToNum s =
    case s of
        "one" -> 1
        "two" -> 2
        _ -> 0

main =
    text (String.fromInt (strToNum "two"))
