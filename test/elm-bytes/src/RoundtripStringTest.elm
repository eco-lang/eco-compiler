module RoundtripStringTest exposing (main)

{-| Strings survive an elm/bytes encode and decode when `Bytes.Decode.string` is given the string's length.

The strings `""`, `"a"`, `"hello"` and `"Hello, World!"` are each round-tripped,
and the program logs `True` only if all of them come back unchanged. The length
passed to the decoder is `String.length`, which equals the UTF-8 byte count only
because every test string is ASCII.

Among what is not tested: non-ASCII text.
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
