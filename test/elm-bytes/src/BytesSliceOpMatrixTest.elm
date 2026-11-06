module BytesSliceOpMatrixTest exposing (main)

{-| Decoding unsigned 8-, 16- and 32-bit integers from a 40-byte `Bytes` value produced by
`Bytes.Decode.bytes` reads from the start of that value.

The buffer is 50 bytes: the big-endian unsigned 32-bit integer 16909060 (bytes 1, 2, 3, 4)
followed by 46 bytes of 9. `Bytes.Decode.bytes 40` takes its first 40 bytes.
Decoding from the start of the result, `unsignedInt8` gives 1, big-endian `unsignedInt16`
gives 258 (0x0102) and big-endian `unsignedInt32` gives 16909060 (0x01020304).

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
