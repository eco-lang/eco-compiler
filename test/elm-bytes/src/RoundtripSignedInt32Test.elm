module RoundtripSignedInt32Test exposing (main)

{-| Roundtrip test for signedInt32.
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
