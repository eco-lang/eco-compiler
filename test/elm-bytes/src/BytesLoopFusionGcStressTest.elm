module BytesLoopFusionGcStressTest exposing (main)

{-| Guard (bytes fusion, `Decode.loop` under GC): decodes 100 freshly encoded
8,000-byte buffers, each with the fused count loop of
`BytesLoopFusionRealOrderTest` (in read order, `Done (List.reverse acc)`), and
checks every decoded list against the list the buffer was encoded from.

An 8,000-byte buffer is just below the 8 KiB large-object threshold, so it is
allocated in the nursery, where a minor GC may move it. The fused loop
allocates a cons cell per item while its read cursor (raw pointers into the
buffer) is live, and the 800,000 cells allocated here make minor GCs fall in
the middle of loops (about 700 minor GCs over the run with a 64 KiB-block
nursery, `ECO_HEAP_CONFIG`). Should a collection move or free the buffer
under a live cursor, decoded values would stop matching and the test prints
the number of mismatching buffers instead of 0.

-}

-- CHECK: BytesLoopFusionGcStressTest: "mismatches=0 total=800000"

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
            List.foldl check ( 0, 0 ) (List.range 0 99)

        output =
            "mismatches=" ++ String.fromInt bad ++ " total=" ++ String.fromInt count

        _ =
            Debug.log "BytesLoopFusionGcStressTest" output
    in
    text output
