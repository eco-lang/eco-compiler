module BytesLargeHeterogeneousBufferTest exposing (main)

{-| A mixed-width encoding of about 12 KB has the right width, and its first values decode correctly.

The sequence is an unsigned 8-bit 42, a big-endian 16-bit 4660 and 3000
big-endian 32-bit 7s, so its width is `1 + 2 + 3000 * 4 = 12003` bytes. Decoding
the first three values and adding them gives `42 + 4660 + 7 = 4709`.

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
