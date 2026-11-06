module BytesIssue20InvalidUtf8StringTest exposing (main)

{-| `Bytes.Decode.string` decodes invalid UTF-8 into a nonsense string.

<https://github.com/elm/bytes/issues/20>

The bytes `C0 00` are not UTF-8 (0xC0 is never valid; a lead byte must be followed by a
continuation byte). Elm 0.19.1 (elm/bytes 1.0.8) combines the bits anyway and returns
`Just "\0"` (code point 0). Decoding must fail (`Nothing`), or at least yield U+FFFD
replacement characters as a standard UTF-8 decoder does.

-}

-- CHECK: {{decoded: (Nothing|Just "�)}}

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.sequence [ E.unsignedInt8 0xC0, E.unsignedInt8 0 ])

        _ =
            Debug.log "decoded" (D.decode (D.string 2) bytes)
    in
    text "done"
