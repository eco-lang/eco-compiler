module RoundtripUnsignedInt8Test exposing (main)

{-| Roundtrip test for unsignedInt8.
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
