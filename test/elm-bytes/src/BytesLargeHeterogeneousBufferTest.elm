module BytesLargeHeterogeneousBufferTest exposing (main)

{-| G2/E9: encode a mixed-width sequence exceeding the 8 KiB large-object
threshold, then decode values back. Forces a Tag_LargeByteHeader through both the
encoder and the decoder. width = 1 + 2 + 3000*4 = 12003 bytes; decoded head is
u8 42, u16 4660, u32 7 -> sum 4709.
-}

-- CHECK: width: 12003
-- CHECK: decoded_sum: 4709

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode
                (E.sequence
                    (E.unsignedInt8 42
                        :: E.unsignedInt16 BE 4660
                        :: List.repeat 3000 (E.unsignedInt32 BE 7)
                    )
                )

        decoder =
            D.map3 (\a b c -> a + b + c)
                D.unsignedInt8
                (D.unsignedInt16 BE)
                (D.unsignedInt32 BE)

        _ =
            Debug.log "width" (Bytes.width bytes)

        _ =
            Debug.log "decoded_sum" (D.decode decoder bytes |> Maybe.withDefault -1)
    in
    text "done"
