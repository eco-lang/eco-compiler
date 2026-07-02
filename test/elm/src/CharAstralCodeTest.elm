module CharAstralCodeTest exposing (main)

{-| G1/E7: Eco's Char is i16 (enforced REP_ABI_001 / CGEN_015), so it cannot hold
a code point > U+FFFF: Char.fromCode clamps a supplementary (astral) code point
to U+FFFF (65535). BMP code points round-trip exactly. Documents the i16-Char
limit (Elm parity would require widening Char across the ABI/codegen/heap).
-}

-- CHECK: bmp: 8364
-- CHECK: emoji: 65535
-- CHECK: clef: 65535

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
    in
    text "done"
