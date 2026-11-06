module BytesSliceViewTest exposing (main)

{-| Decoding a big-endian unsigned 32-bit integer from a 40-byte `Bytes` value produced by
`Bytes.Decode.bytes` gives the first four bytes of that value.

The buffer is 50 bytes: the big-endian unsigned 32-bit integer 16909060 (bytes 1, 2, 3, 4)
followed by 46 bytes of 9. `Bytes.Decode.bytes 40` takes its first 40 bytes.
Reading a big-endian `unsignedInt32` from the result gives 16909060.

-}

-- CHECK: from_slice: 16909060

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        buffer =
            E.encode
                (E.sequence (E.unsignedInt32 BE 16909060 :: List.repeat 46 (E.unsignedInt8 9)))

        result =
            D.decode (D.bytes 40) buffer
                |> Maybe.andThen (\s -> D.decode (D.unsignedInt32 BE) s)
                |> Maybe.withDefault -1

        _ =
            Debug.log "from_slice" result
    in
    text "done"
