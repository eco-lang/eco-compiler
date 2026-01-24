module EncodeBytesTest exposing (main)

{-| Test Bytes.Encode.bytes embedding bytes in bytes.
-}

-- CHECK: EncodeBytesTest: 4

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        innerBytes =
            E.encode (E.unsignedInt32 BE 0x12345678)

        outerBytes =
            E.encode (E.bytes innerBytes)

        result =
            Bytes.width outerBytes

        _ =
            Debug.log "EncodeBytesTest" result
    in
    text (String.fromInt result)
