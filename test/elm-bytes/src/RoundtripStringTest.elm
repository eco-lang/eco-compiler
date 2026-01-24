module RoundtripStringTest exposing (main)

{-| Roundtrip test for strings.
-}

-- CHECK: RoundtripStringTest: True

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtrip : String -> Bool
roundtrip s =
    let
        len =
            String.length s

        encoded =
            E.encode (E.string s)

        decoded =
            D.decode (D.string len) encoded
    in
    decoded == Just s


main =
    let
        allPass =
            roundtrip ""
                && roundtrip "a"
                && roundtrip "hello"
                && roundtrip "Hello, World!"

        _ =
            Debug.log "RoundtripStringTest" allPass
    in
    text (if allPass then "True" else "False")
