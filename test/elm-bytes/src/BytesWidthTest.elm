module BytesWidthTest exposing (main)

{-| Test Bytes.width function.
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
