module BytesSliceOfLargeParentGCTest exposing (main)

{-| A 40-byte `Bytes` value cut from a larger buffer with `Bytes.Decode.bytes` reads the same before and after a burst of unrelated allocation.

The buffer is the big-endian 32-bit value 16909060 (bytes `1 2 3 4`) followed
by 46 bytes of 9. Its first 40 bytes are taken as a new `Bytes` value. The test
reads that value's first byte (`1`), builds and concatenates over five thousand
strings, and then reads the 32-bit value at its start again, which must
still be `16909060`.

## eco

Exercises minor-GC evacuation of a `Tag_ByteBufferSlice` of at least 32 bytes (gap G2,
finding F1 in `plans/string-bytes-testing-gap.md`). The object-size function (now
`getObjectSizeFromHeader` in `runtime/src/allocator/AllocatorCommon.hpp`) once omitted
that tag, so the collector copied only 8 of the slice's 24 bytes and lost its base and
offset. The slice is read before the string churn so that it is live when the churn
triggers a minor GC; a corrupted slice gives garbage or aborts the collector.

-}

-- CHECK: first_byte: 1
-- CHECK: after_gc: 16909060

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        buffer =
            E.encode
                (E.sequence (E.unsignedInt32 BE 16909060 :: List.repeat 46 (E.unsignedInt8 9)))

        sliceM =
            D.decode (D.bytes 40) buffer

        firstByte =
            sliceM
                |> Maybe.andThen (\s -> D.decode D.unsignedInt8 s)
                |> Maybe.withDefault -1

        -- Allocation while `sliceM` is still in use; only its length is consulted.
        churn =
            List.range 0 5000
                |> List.map (\n -> String.repeat 20 (String.fromInt n))
                |> String.concat

        afterGc =
            if String.length churn > 0 then
                sliceM
                    |> Maybe.andThen (\s -> D.decode (D.unsignedInt32 BE) s)
                    |> Maybe.withDefault -2

            else
                -3

        _ =
            Debug.log "first_byte" firstByte

        _ =
            Debug.log "after_gc" afterGc
    in
    text "done"
