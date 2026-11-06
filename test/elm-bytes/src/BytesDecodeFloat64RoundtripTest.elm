module BytesDecodeFloat64RoundtripTest exposing (main)

{-| A Float encoded with `Bytes.Encode.float64` little-endian decodes back to exactly the same Float.

The value is `3.141592653589793`. Between encoding and decoding the program
builds and concatenates about two thousand strings, so the bytes are decoded after
other allocation has happened. The logged `True` is the equality check.

-}

-- CHECK: BytesDecodeFloat64RoundtripTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        original : Float
        original =
            3.141592653589793

        bytes : Bytes
        bytes =
            E.encode (E.float64 LE original)

        -- Allocation between encoding and decoding; the result is unused.
        _ =
            List.range 0 2000
                |> List.map String.fromInt
                |> String.concat

        decoded : Float
        decoded =
            D.decode (D.float64 LE) bytes
                |> Maybe.withDefault 0.0

        match : Bool
        match =
            decoded == original

        _ =
            Debug.log "BytesDecodeFloat64RoundtripTest" match
    in
    text (String.fromFloat decoded)
