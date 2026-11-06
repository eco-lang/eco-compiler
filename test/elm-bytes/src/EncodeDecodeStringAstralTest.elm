module EncodeDecodeStringAstralTest exposing (main)

{-| A string containing a character outside the Basic Multilingual Plane survives
a round trip through Bytes.Encode.string and Bytes.Decode.string.

The string is `"a😀b"`. U+1F600 takes 4 bytes in UTF-8, so the logged width is
1 + 4 + 1 = 6. The decoded string is compared with the original, and the
comparison is logged as `True` when they are equal.

-}

-- CHECK: width: 6
-- CHECK: roundtrip_ok: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        original =
            "a😀b"

        bytes =
            E.encode (E.string original)

        decoded =
            D.decode (D.string (Bytes.width bytes)) bytes
                |> Maybe.withDefault "FAIL"

        _ =
            Debug.log "width" (Bytes.width bytes)

        _ =
            Debug.log "roundtrip_ok" (decoded == original)
    in
    text "done"
