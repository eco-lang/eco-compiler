module BytesEncoderSurvivesGCTest exposing (main)

{-| Build many `E.unsignedInt16` encoder nodes, force GC, then encode them.

    Exercises `makeEncoder2_pi` in BytesExports.cpp: each encoder node is a
    Custom holding `(endianness_hptr, i64)`. Under a broken 2-bit bitmap
    (e.g. 2 instead of 4) GC would skip tracing the endianness HPointer,
    leaving a stale reference after any intervening minor GC. Walking the
    encoder tree after GC would then crash or produce wrong bytes.
-}

-- CHECK: BytesEncoderSurvivesGCTest: 2000

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        -- 1000 encoder nodes, each referencing the BE endianness constant.
        encoders : List E.Encoder
        encoders =
            List.repeat 1000 (E.unsignedInt16 BE 0xABCD)

        -- Force significant nursery churn so a minor GC runs while the
        -- encoder list is live. If the endianness HPointers in each node
        -- aren't traced, they become stale and `E.sequence` will read
        -- corrupted state when walking the tree.
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
