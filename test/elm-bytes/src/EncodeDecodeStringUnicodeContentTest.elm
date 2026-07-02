module EncodeDecodeStringUnicodeContentTest exposing (main)

{-| G5/E19: encode a BMP non-ASCII string (2- and 3-byte UTF-8) to bytes and
decode it back, asserting CONTENT equality. Compared in Elm and logged as a Bool
(Debug.log \u-escapes non-ASCII). Should pass — BMP UTF-8 round-trips fine.
-}

-- CHECK: unicode_ok: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        original =
            "café €λ"

        bytes =
            E.encode (E.string original)

        decoded =
            D.decode (D.string (Bytes.width bytes)) bytes
                |> Maybe.withDefault "FAIL"

        _ =
            Debug.log "unicode_ok" (decoded == original)
    in
    text "done"
