module EncodeStringUnicodeTest exposing (main)

{-| `Bytes.Encode.string` writes a string as UTF-8, so a two-byte character takes two bytes.

The test encodes three copies of `é` (U+00E9) and logs the width of the result, 6.
-}

-- CHECK: EncodeStringUnicodeTest: 6

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.string "\u{00E9}\u{00E9}\u{00E9}")

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeStringUnicodeTest" result
    in
    text (String.fromInt result)
