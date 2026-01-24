module RoundtripUnsignedInt32Test exposing (main)

{-| Roundtrip test for unsignedInt32.
-}

-- CHECK: RoundtripUnsignedInt32Test: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtripBE : Int -> Bool
roundtripBE n =
    D.decode (D.unsignedInt32 BE) (E.encode (E.unsignedInt32 BE n)) == Just n


roundtripLE : Int -> Bool
roundtripLE n =
    D.decode (D.unsignedInt32 LE) (E.encode (E.unsignedInt32 LE n)) == Just n


main =
    let
        allPass =
            roundtripBE 0
                && roundtripBE 0x12345678
                && roundtripLE 0
                && roundtripLE 0x12345678

        _ =
            Debug.log "RoundtripUnsignedInt32Test" allPass
    in
    text (if allPass then "True" else "False")
