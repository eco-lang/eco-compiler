module BytesDecodeI32RoundtripTest exposing (main)

{-| Roundtrip: encode an Int32 and decode it back, verifying equality.

    Exercises `makeTuple2_ii` in BytesExports.cpp: each decoder step builds
    a `(offset, value)` tuple with two i64 slots. Under a broken 2-bit
    bitmap (e.g. 3 instead of 5) GC would treat slot 1 as an HPointer,
    producing either a crash or a corrupted value after any minor GC.
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

        -- Allocate churn between encode and decode to trigger a minor GC
        -- while the decoder's (offset, value) tuples are live.
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
