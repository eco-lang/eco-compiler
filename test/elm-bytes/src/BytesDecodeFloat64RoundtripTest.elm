module BytesDecodeFloat64RoundtripTest exposing (main)

{-| Roundtrip: encode a Float64 and decode it back, verifying equality.

    Exercises `makeTuple2_if` in BytesExports.cpp: the float-producing
    decoders build a `(offset:i64, value:f64)` tuple. A broken 2-bit bitmap
    (e.g. 3 instead of 9) would misread both slot kinds, misprinting the
    Float on projection and potentially crashing GC.
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

        -- Allocate churn between encode and decode to trigger minor GC.
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
