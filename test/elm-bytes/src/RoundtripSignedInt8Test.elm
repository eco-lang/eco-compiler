module RoundtripSignedInt8Test exposing (main)

{-| Roundtrip test for signedInt8.
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
