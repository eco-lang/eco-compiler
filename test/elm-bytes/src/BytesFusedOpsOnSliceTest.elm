module BytesFusedOpsOnSliceTest exposing (main)

{-| G7/E22 (fail-now-in-debug IF fusion fires, F3): a multi-field decoder run on a
slice. If the bytes-fusion pass fuses this decoder, the input cursor is set up via
bf.decoder.cursor.init -> elm_bytebuffer_len on the slice -> abort (assert builds).
If fusion does not fire, the non-fused reads are slice-safe and this passes.
buffer[0..1] = u16 BE 258, buffer[2..3] = u16 BE 772 -> 258*10000 + 772 = 2580772.
-}

-- CHECK: fused_pair: 2580772

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        buffer =
            E.encode
                (E.sequence
                    (E.unsignedInt16 BE 258
                        :: E.unsignedInt16 BE 772
                        :: List.repeat 46 (E.unsignedInt8 0)
                    )
                )

        decoder =
            D.map2 (\a b -> a * 10000 + b) (D.unsignedInt16 BE) (D.unsignedInt16 BE)

        pair =
            D.decode (D.bytes 40) buffer
                |> Maybe.andThen (\s -> D.decode decoder s)
                |> Maybe.withDefault -1

        _ =
            Debug.log "fused_pair" pair
    in
    text "done"
