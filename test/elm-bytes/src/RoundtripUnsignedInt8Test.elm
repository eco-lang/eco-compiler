module RoundtripUnsignedInt8Test exposing (main)

{-| Integers survive an `unsignedInt8` encode and decode with elm/bytes, from 0 up to 255.

The values 0, 1, 127, 128 and 255 are each round-tripped, and the program logs
`True` only if all of them come back unchanged.
-}

-- CHECK: RoundtripUnsignedInt8Test: True

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtrip : Int -> Bool
roundtrip n =
    let
        encoded =
            E.encode (E.unsignedInt8 n)

        decoded =
            D.decode D.unsignedInt8 encoded
    in
    decoded == Just n


main =
    let
        allPass =
            roundtrip 0
                && roundtrip 1
                && roundtrip 127
                && roundtrip 128
                && roundtrip 255

        _ =
            Debug.log "RoundtripUnsignedInt8Test" allPass
    in
    text (if allPass then "True" else "False")
