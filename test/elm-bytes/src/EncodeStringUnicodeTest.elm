module EncodeStringUnicodeTest exposing (main)

{-| Test Bytes.Encode.string with Unicode characters.
    UTF-8 encoding: multi-byte characters take more bytes.
-}

-- CHECK: EncodeStringUnicodeTest: 6

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        -- Two-byte UTF-8 characters
        bytes =
            E.encode (E.string "\u{00E9}\u{00E9}\u{00E9}")

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeStringUnicodeTest" result
    in
    text (String.fromInt result)
