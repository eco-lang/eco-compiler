module RoundtripFloat32Test exposing (main)

{-| Roundtrip test for float32.
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
