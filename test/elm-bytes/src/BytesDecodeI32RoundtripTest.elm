module BytesDecodeI32RoundtripTest exposing (main)

{-| An Int encoded with `Bytes.Encode.unsignedInt32` big-endian decodes back to the same Int with `Bytes.Decode.unsignedInt32`.

The value is `0x12345678`. Between encoding and decoding the program builds and
concatenates about two thousand strings, so the bytes are decoded after other
allocation has happened. The logged `True` is the equality check.

-}

-- CHECK: BytesDecodeI32RoundtripTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        original : Int
        original =
            0x12345678

        bytes : Bytes
        bytes =
            E.encode (E.unsignedInt32 BE original)

        -- Allocation between encoding and decoding; the result is unused.
        _ =
            List.range 0 2000
                |> List.map String.fromInt
                |> String.concat

        decoded : Int
        decoded =
            D.decode (D.unsignedInt32 BE) bytes
                |> Maybe.withDefault -1

        match : Bool
        match =
            decoded == original

        _ =
            Debug.log "BytesDecodeI32RoundtripTest" match
    in
    text (String.fromInt decoded)
