module CharAstralCodeTest exposing (main)

{-| `Char.fromCode` and `Char.toCode` round-trip Unicode code points, including
astral ones (above 0xFFFF) and the largest, 0x10FFFF, and `Char.fromCode` turns
a code below 0 or above 0x10FFFF into U+FFFD (65533).

The test round-trips U+20AC, U+1F600, U+1D11E and U+10FFFF, and converts -1
and 0x110000.

-}

-- CHECK: bmp: 8364
-- CHECK: emoji: 128512
-- CHECK: clef: 119070
-- CHECK: maxcp: 1114111
-- CHECK: negative: 65533
-- CHECK: beyond: 65533

import Char
import Html exposing (text)


main =
    let
        _ =
            Debug.log "bmp" (Char.toCode (Char.fromCode 0x20AC))

        _ =
            Debug.log "emoji" (Char.toCode (Char.fromCode 0x0001F600))

        _ =
            Debug.log "clef" (Char.toCode (Char.fromCode 0x0001D11E))

        _ =
            Debug.log "maxcp" (Char.toCode (Char.fromCode 0x0010FFFF))

        _ =
            Debug.log "negative" (Char.toCode (Char.fromCode -1))

        _ =
            Debug.log "beyond" (Char.toCode (Char.fromCode 0x00110000))
    in
    text "done"
