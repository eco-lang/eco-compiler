module RoundtripUnsignedInt16Test exposing (main)

{-| Roundtrip test for unsignedInt16 BE/LE.
-}

-- CHECK: RoundtripUnsignedInt16Test: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtripBE : Int -> Bool
roundtripBE n =
    D.decode (D.unsignedInt16 BE) (E.encode (E.unsignedInt16 BE n)) == Just n


roundtripLE : Int -> Bool
roundtripLE n =
    D.decode (D.unsignedInt16 LE) (E.encode (E.unsignedInt16 LE n)) == Just n


main =
    let
        allPass =
            roundtripBE 0
                && roundtripBE 0xFFFF
                && roundtripBE 0x1234
                && roundtripLE 0
                && roundtripLE 0xFFFF
                && roundtripLE 0x1234

        _ =
            Debug.log "RoundtripUnsignedInt16Test" allPass
    in
    text (if allPass then "True" else "False")
