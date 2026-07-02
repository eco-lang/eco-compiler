module BytesSliceOfLargeParentGCTest exposing (main)

{-| G2/E11 (fail-now, F1): a >=32-byte byte slice that survives a minor GC.
getObjectSize omits Tag_ByteBufferSlice, so the collector evacuates only 8 of the
slice's 24 bytes, dropping its base+offset and corrupting it. We force the slice
to exist before heavy nursery churn (which triggers a minor GC while the slice is
live), then read it again afterwards. Expected 16909060; a corrupted slice yields
garbage or aborts the collector.
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

        -- Force the slice into existence and read a byte BEFORE the churn.
        firstByte =
            sliceM
                |> Maybe.andThen (\s -> D.decode D.unsignedInt8 s)
                |> Maybe.withDefault -1

        -- Heavy nursery churn -> minor GC while `sliceM` is still live.
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
