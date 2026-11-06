module RoundtripSignedInt32Test exposing (main)

{-| Integers survive a big-endian `signedInt32` encode and decode with elm/bytes, including both ends of the signed 32-bit range.

The values 0, 1, -1, 2147483647 and -2147483648 are each round-tripped, and the
program logs `True` only if all of them come back unchanged.
-}

-- CHECK: RoundtripSignedInt32Test: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtrip : Int -> Bool
roundtrip n =
    D.decode (D.signedInt32 BE) (E.encode (E.signedInt32 BE n)) == Just n


main =
    let
        allPass =
            roundtrip 0
                && roundtrip 1
                && roundtrip -1
                && roundtrip 2147483647
                && roundtrip -2147483648

        _ =
            Debug.log "RoundtripSignedInt32Test" allPass
    in
    text (if allPass then "True" else "False")
