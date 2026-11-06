module BytesWidthTest exposing (main)

{-| `Bytes.width` gives 1, 2, 4 and 8 for the encodings of an unsigned 8-bit integer, a
big-endian unsigned 16-bit and 32-bit integer, and a big-endian 64-bit float.

The program logs `True` only when all four widths match.

-}

-- CHECK: BytesWidthTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        b1 =
            E.encode (E.unsignedInt8 0)

        b2 =
            E.encode (E.unsignedInt16 BE 0)

        b4 =
            E.encode (E.unsignedInt32 BE 0)

        b8 =
            E.encode (E.float64 BE 0)

        allCorrect =
            (Bytes.width b1 == 1)
                && (Bytes.width b2 == 2)
                && (Bytes.width b4 == 4)
                && (Bytes.width b8 == 8)

        _ =
            Debug.log "BytesWidthTest" allCorrect
    in
    text (if allCorrect then "True" else "False")
