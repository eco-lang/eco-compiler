module EncodeDecodeStringUnicodeContentTest exposing (main)

{-| A string with two- and three-byte UTF-8 characters survives a round trip through
`Bytes.Encode.string` and `Bytes.Decode.string`.

The string `"café €λ"` is encoded, then decoded with `Bytes.Decode.string` given the
encoded byte width. The test logs whether the decoded string equals the original, so the
expected output is `True`; comparing in Elm avoids depending on how `Debug.log` escapes
non-ASCII characters.
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
