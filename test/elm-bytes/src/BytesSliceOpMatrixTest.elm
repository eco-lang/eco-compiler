module BytesSliceOpMatrixTest exposing (main)

{-| G7/E21: run the safe consumer ops (decode primitives) against one >=32-byte
slice, to catch any slice-hostile sibling of Bytes.width. Deliberately excludes
width (covered by E20) so this test reaches all the reads. buffer[0..3] = u32
0x01020304, so u8 -> 1, u16 BE -> 258, u32 BE -> 16909060.
-}

-- CHECK: slice_u8: 1
-- CHECK: slice_u16: 258
-- CHECK: slice_u32: 16909060

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

        readWith decoder =
            sliceM
                |> Maybe.andThen (\s -> D.decode decoder s)
                |> Maybe.withDefault -1

        _ =
            Debug.log "slice_u8" (readWith D.unsignedInt8)

        _ =
            Debug.log "slice_u16" (readWith (D.unsignedInt16 BE))

        _ =
            Debug.log "slice_u32" (readWith (D.unsignedInt32 BE))
    in
    text "done"
