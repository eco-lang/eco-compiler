module BytesWidthOfSliceTest exposing (main)

{-| G7/E20 (fail-now, F3): the minimal reproduction of the reported crash.
`D.bytes 40` on a 50-byte buffer yields a Tag_ByteBufferSlice (40 >= 32). Calling
Bytes.width on that slice routes through elm_bytebuffer_len -> resolveByteBufferBody,
which asserts on a slice (aborts in assert builds; returns 40 in release via
header aliasing). This is what Inflate.ZLib.slice does in the PNG decoder.
-}

-- CHECK: slice_width: 40

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        buffer =
            E.encode (E.sequence (List.repeat 50 (E.unsignedInt8 7)))

        sliceWidth =
            D.decode (D.bytes 40) buffer
                |> Maybe.map Bytes.width
                |> Maybe.withDefault -1

        _ =
            Debug.log "slice_width" sliceWidth
    in
    text "done"
