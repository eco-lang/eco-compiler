module EncodeBytesTest exposing (main)

{-| Bytes.Encode.bytes embeds an existing Bytes value in a new encoding.

A 4-byte value is encoded, then re-encoded with `E.bytes`, and the logged width
of the result is 4.

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
