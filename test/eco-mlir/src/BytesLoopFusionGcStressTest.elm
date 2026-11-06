module BytesLoopFusionGcStressTest exposing (main)

{-| A thousand 8,000-byte buffers, each encoded from a fresh list and decoded with a count-based `Bytes.Decode.loop`, all decode back to the lists they were encoded from.

For each `k` from 0 to 999, `itemsFor k` gives 8,000 bytes, which are encoded
with `Bytes.Encode.sequence` and decoded by a loop that reads 8,000 unsigned
bytes and ends with `Done (List.reverse acc)`, so the list comes out in read
order. The program allocates a good deal per buffer, in the item list, the
encoder and the decoded list.

The output counts buffers whose decoded list differs from the original, or that
fail to decode, and the total number of items decoded. The test expects
`mismatches=0` and `8000000` items.

## eco

Exercises fused `Bytes.Decode.loop` decodes under GC, in the shape of
test/eco-mlir/src/BytesLoopFusionRealOrderTest.elm with `Done (List.reverse acc)`. An 8,000-byte
buffer is just below the 8 KiB large-object threshold, so it lives in the nursery, where a minor
GC moves it. About 1 MB is allocated per buffer, so minor GCs run between and around the fused
decodes at the default 64 MB eden. A fused decoder or encoder holding a stale pointer into a
moved buffer, or a fused loop list built wrong across a collection, shows up as mismatches.

Not exercised: a GC while the loop's read cursor is live. The loop body has no GC point:
runtime/src/codegen/Passes/EcoListTemplate.cpp turns its cons cells into
`eco_scratch_push_scalar` calls (gc-leaf), and `eco_scratch_finish`
(runtime/src/allocator/RuntimeExports.h) builds the list after the loop. A GC with a live
encoder cursor is test/eco-mlir/src/BytesFusedEncodeCursorSurvivesGCTest.elm; one with live
decoder cursors is test/bf-codegen/bf_cursor_survives_minor_gc.mlir. The CHECK-MLIR lines assert
the decode loop was fused.

-}

-- CHECK: BytesLoopFusionGcStressTest: "mismatches=0 total=8000000"
-- CHECK-MLIR: bf.decoder.cursor.init
-- CHECK-MLIR: bf.read.u8

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


itemsFor : Int -> List Int
itemsFor k =
    List.map (\i -> modBy 256 (i * 7 + k)) (List.range 0 7999)


decodeAll : Bytes -> Maybe (List Int)
decodeAll bytes =
    D.decode
        (D.loop ( 8000, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
            )
        )
        bytes


main =
    let
        check k ( mismatches, total ) =
            let
                expected =
                    itemsFor k

                bytes =
                    E.encode (E.sequence (List.map E.unsignedInt8 expected))
            in
            case decodeAll bytes of
                Just decoded ->
                    if decoded == expected then
                        ( mismatches, total + List.length decoded )

                    else
                        ( mismatches + 1, total + List.length decoded )

                Nothing ->
                    ( mismatches + 1, total )

        ( bad, count ) =
            List.foldl check ( 0, 0 ) (List.range 0 999)

        output =
            "mismatches=" ++ String.fromInt bad ++ " total=" ++ String.fromInt count

        _ =
            Debug.log "BytesLoopFusionGcStressTest" output
    in
    text output
