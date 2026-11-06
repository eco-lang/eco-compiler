module EncodeEmptyStringTest exposing (main)

{-| `Json.Encode.string ""` encodes to the two-character JSON text `""`, and decoding that
with `Json.Decode.string` gives back the empty string.
-}

-- CHECK: encoded: "\"\""
-- CHECK: encoded_len: 2
-- CHECK: decoded: Ok ""

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode


main =
    let
        encoded =
            Encode.encode 0 (Encode.string "")

        _ =
            Debug.log "encoded" encoded

        _ =
            Debug.log "encoded_len" (String.length encoded)

        _ =
            Debug.log "decoded" (Decode.decodeString Decode.string encoded)
    in
    text "done"
