module RoundtripSignedInt16Test exposing (main)

{-| Roundtrip test for signedInt16.
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
