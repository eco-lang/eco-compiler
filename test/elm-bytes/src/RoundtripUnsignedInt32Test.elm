module RoundtripUnsignedInt32Test exposing (main)

{-| Integers survive an `unsignedInt32` encode and decode with elm/bytes in both byte orders.

The values 0 and 0x12345678 are each round-tripped big-endian and then
little-endian, and the program logs `True` only if all four come back unchanged.

Among what is not tested: values at or above 2^31.
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
