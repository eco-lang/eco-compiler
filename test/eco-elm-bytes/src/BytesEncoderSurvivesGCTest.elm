module BytesEncoderSurvivesGCTest exposing (main)

{-| A list of a thousand `Bytes.Encode.unsignedInt16` encoders built before a burst of unrelated allocation still encodes to 2000 bytes once it is run.

The encoders are built first, then the program builds and concatenates over
five thousand strings, and only then are the encoders combined with
`Bytes.Encode.sequence` and run. Only the width is checked, not the bytes.

## eco

Exercises `makeEncoder2_pi` in elm-kernel-cpp/src/bytes/BytesExports.cpp: each
encoder node is a Custom holding `(endianness_hptr, i64)`. With a wrong
2-bit slot-kind bitmap (e.g. 2 instead of 4) the GC would skip tracing the
endianness HPointer, leaving a stale reference
after a minor GC. The churn between building and using the encoders forces
that minor GC. Slot kinds: HEAP_019 in design_docs/invariants.csv.

-}

-- CHECK: BytesEncoderSurvivesGCTest: 2000

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        encoders : List E.Encoder
        encoders =
            List.repeat 1000 (E.unsignedInt16 BE 0xABCD)

        -- Allocation between building the encoders and running them; the result is unused.
        _ =
            List.range 0 5000
                |> List.map (\n -> String.repeat 20 (String.fromInt n))
                |> String.concat

        bytes : Bytes
        bytes =
            E.encode (E.sequence encoders)

        width : Int
        width =
            Bytes.width bytes

        _ =
            Debug.log "BytesEncoderSurvivesGCTest" width
    in
    text (String.fromInt width)
