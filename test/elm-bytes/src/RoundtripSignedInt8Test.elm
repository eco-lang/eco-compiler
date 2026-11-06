module RoundtripSignedInt8Test exposing (main)

{-| Integers survive a `signedInt8` encode and decode with elm/bytes, including both ends of the signed 8-bit range.

The values 0, 1, -1, 127 and -128 are each round-tripped, and the program logs
`True` only if all of them come back unchanged.
-}

-- CHECK: RoundtripSignedInt8Test: True

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtrip : Int -> Bool
roundtrip n =
    let
        encoded =
            E.encode (E.signedInt8 n)

        decoded =
            D.decode D.signedInt8 encoded
    in
    decoded == Just n


main =
    let
        allPass =
            roundtrip 0
                && roundtrip 1
                && roundtrip -1
                && roundtrip 127
                && roundtrip -128

        _ =
            Debug.log "RoundtripSignedInt8Test" allPass
    in
    text (if allPass then "True" else "False")
