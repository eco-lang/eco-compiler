module EncodeDecodeStringAstralTest exposing (main)

{-| G1/E8: encode an astral string to UTF-8 bytes and decode it back. The Bytes
UTF-8 encode/decode paths combine/emit surrogate pairs correctly, so this should
round-trip. Width of "a😀b" = 1 + 4 (4-byte UTF-8 for U+1F600) + 1 = 6 bytes. The
content is compared in Elm and logged as a Bool, because Debug.log renders
non-ASCII / astral chars with \u escapes.
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
