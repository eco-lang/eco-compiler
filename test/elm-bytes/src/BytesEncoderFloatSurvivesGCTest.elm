module BytesEncoderFloatSurvivesGCTest exposing (main)

{-| Build a Float encoder, force GC, then encode + decode to verify.

    Exercises `makeEncoder2_pf` in BytesExports.cpp: each `E.float64`
    encoder node is a Custom holding `(endianness_hptr, f64)`. Under a
    broken 2-bit bitmap (e.g. 2 instead of 8) GC would skip tracing the
    endianness HPointer AND misread slot 1 as boxed, corrupting the Float
    value after any minor GC.
-}

-- CHECK: BytesEncoderFloatSurvivesGCTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        original : Float
        original =
            2.718281828459045

        encoder : E.Encoder
        encoder =
            E.float64 LE original

        -- Churn to trigger a minor GC between encoder construction and use.
        _ =
            List.range 0 5000
                |> List.map (\n -> String.repeat 20 (String.fromInt n))
                |> String.concat

        bytes : Bytes
        bytes =
            E.encode encoder

        decoded : Float
        decoded =
            D.decode (D.float64 LE) bytes
                |> Maybe.withDefault 0.0

        match : Bool
        match =
            decoded == original

        _ =
            Debug.log "BytesEncoderFloatSurvivesGCTest" match
    in
    text (String.fromFloat decoded)
