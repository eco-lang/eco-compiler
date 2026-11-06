module RoundtripFloat32Test exposing (main)

{-| Floats survive a big-endian `float32` encode and decode with elm/bytes to within 0.0001.

The values 0, 1, -1 and 3.14159 are each round-tripped. A tolerance is used
because a 32-bit float cannot hold every 64-bit value exactly; the program logs
`True` only if every decoded value is within it.
-}

-- CHECK: RoundtripFloat32Test: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundtrip : Float -> Bool
roundtrip n =
    let
        decoded =
            D.decode (D.float32 BE) (E.encode (E.float32 BE n))
    in
    case decoded of
        Just v ->
            abs (v - n) < 0.0001

        Nothing ->
            False


main =
    let
        allPass =
            roundtrip 0.0
                && roundtrip 1.0
                && roundtrip -1.0
                && roundtrip 3.14159

        _ =
            Debug.log "RoundtripFloat32Test" allPass
    in
    text (if allPass then "True" else "False")
