module BytesSliceViewTest exposing (main)

{-| G2/E10: produce a >=32-byte slice via `D.bytes 40` (a real Tag_ByteBufferSlice)
and read a primitive back out of it. Exercises the slice-aware decode read path
(resolveByteBufferView). Should pass — this is the safe consumer path, distinct
from Bytes.width (E20). buffer[0..3] = u32 0x01020304 = 16909060.
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
