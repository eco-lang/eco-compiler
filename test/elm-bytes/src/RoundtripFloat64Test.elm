module RoundtripFloat64Test exposing (main)

{-| Floats survive a big-endian `float64` encode and decode with elm/bytes exactly.

The values 0, 1, -1, 3.141592653589793 and the largest finite double,
1.7976931348623157e308, are each round-tripped and compared with `==`. The
program logs `True` only if all of them come back unchanged.
-}

-- CHECK: RoundtripFloat64Test: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtrip : Float -> Bool
roundtrip n =
    D.decode (D.float64 BE) (E.encode (E.float64 BE n)) == Just n


main =
    let
        allPass =
            roundtrip 0.0
                && roundtrip 1.0
                && roundtrip -1.0
                && roundtrip 3.141592653589793
                && roundtrip 1.7976931348623157e308

        _ =
            Debug.log "RoundtripFloat64Test" allPass
    in
    text (if allPass then "True" else "False")
