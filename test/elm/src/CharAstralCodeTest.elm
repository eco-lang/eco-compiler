module CharAstralCodeTest exposing (main)

{-| G1/E7: a Char is a Unicode code point held in an i32 (REP_ABI_001 /
CGEN_015), so `Char.fromCode` keeps a supplementary (astral) code point and
`Char.toCode` gives it back exactly, as in Elm. A code below 0 or above
0x10FFFF becomes U+FFFD (65533), as elm/core's JS `_Char_fromCode` does; the
`eco.char.fromInt` intrinsic and the `Elm_Kernel_Char_fromCode` kernel agree.
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
