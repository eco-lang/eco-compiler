module EndiannessBELETest exposing (main)

{-| Test that BE and LE produce different byte orders.
-}

-- CHECK: EndiannessBELETest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        value =
            0x1234

        beBytesDecoded =
            D.decode (D.unsignedInt16 LE) (E.encode (E.unsignedInt16 BE value))

        leBytesDecoded =
            D.decode (D.unsignedInt16 BE) (E.encode (E.unsignedInt16 LE value))

        -- BE encoded, LE decoded should give reversed bytes
        -- 0x1234 BE = [0x12, 0x34], decoded as LE = 0x3412
        result =
            (beBytesDecoded == Just 0x3412)
                && (leBytesDecoded == Just 0x3412)

        _ =
            Debug.log "EndiannessBELETest" result
    in
    text (if result then "True" else "False")
