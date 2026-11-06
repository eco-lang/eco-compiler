module BytesEncoderFloatSurvivesGCTest exposing (main)

{-| A `Bytes.Encode.float64` encoder built before a burst of unrelated allocation still encodes its Float exactly once it is run.

The encoder for `2.718281828459045` (little-endian) is built first, then the
program builds and concatenates over five thousand strings, and only then is the
encoder run with `Bytes.Encode.encode`. Decoding the result must give back the
same Float; the logged `True` is that equality check.

## eco

Exercises `makeEncoder2_pf` in elm-kernel-cpp/src/bytes/BytesExports.cpp: each
encoder node is a Custom holding `(endianness_hptr, f64)`. With a wrong
2-bit slot-kind bitmap (e.g. 2 instead of 8) the GC would skip tracing the
endianness HPointer and misread slot 1 as boxed, corrupting the Float
after a minor GC. The churn between building and using the encoders forces
that minor GC. Slot kinds: HEAP_019 in design_docs/invariants.csv.

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

        -- Allocation between building the encoder and running it; the result is unused.
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
