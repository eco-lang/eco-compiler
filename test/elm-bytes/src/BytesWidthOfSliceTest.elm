module BytesWidthOfSliceTest exposing (main)

{-| `Bytes.width` of the `Bytes` value that `Bytes.Decode.bytes 40` takes from a 50-byte buffer
is 40.

The buffer is 50 bytes of 7.

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
