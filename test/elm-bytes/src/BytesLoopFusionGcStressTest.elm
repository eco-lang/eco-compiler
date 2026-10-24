module BytesLoopFusionGcStressTest exposing (main)

{-| Guard (bytes fusion, `Decode.loop` under GC): encodes 1,000 fresh
8,000-byte buffers, decodes each with the fused count loop of
`BytesLoopFusionRealOrderTest` (in read order, `Done (List.reverse acc)`),
and checks every decoded list against the list the buffer was encoded from.

An 8,000-byte buffer is just below the 8 KiB large-object threshold, so it is
allocated in the nursery, where a minor GC moves it. The program allocates
about 1 MB per buffer (the item lists, the encoder tree, the decoded list), so
at the default heap config (no `ECO_HEAP_CONFIG`; 64 MB eden) minor GCs run
between and around the fused decodes: observed 2026-10-24, 14 minor GCs. Each
one moves the buffers that are live at that point. The decoded values stop
matching if a fused decoder or encoder kept a stale pointer into a moved
buffer, or if the fused loop's list were built wrong across a collection; the
test then prints the number of mismatching buffers instead of 0.

What this does NOT exercise: a GC while the fused loop's read cursor is live.
The loop body has no GC point: EcoListTemplate turns its cons cells into
`eco_scratch_push_scalar` calls (gc-leaf), and the list is built by
`eco_scratch_finish` after the loop, when the cursor is dead. Were a GC point
ever to appear in the loop, BFToLLVM would re-derive the cursor around it
(BFOPS\_039). A GC while an encoder cursor is live is
`BytesFusedEncodeCursorSurvivesGCTest`; one while decoder cursors are live is
the codegen fixture `test/bf-codegen/bf_cursor_survives_minor_gc.mlir`.

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
