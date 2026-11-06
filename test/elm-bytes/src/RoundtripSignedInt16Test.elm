module RoundtripSignedInt16Test exposing (main)

{-| Integers survive a big-endian `signedInt16` encode and decode with elm/bytes, including both ends of the signed 16-bit range.

The values 0, 1, -1, 32767 and -32768 are each round-tripped, and the program
logs `True` only if all of them come back unchanged.
-}

-- CHECK: RoundtripSignedInt16Test: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtrip : Int -> Bool
roundtrip n =
    D.decode (D.signedInt16 BE) (E.encode (E.signedInt16 BE n)) == Just n


main =
    let
        allPass =
            roundtrip 0
                && roundtrip 1
                && roundtrip -1
                && roundtrip 32767
                && roundtrip -32768

        _ =
            Debug.log "RoundtripSignedInt16Test" allPass
    in
    text (if allPass then "True" else "False")
