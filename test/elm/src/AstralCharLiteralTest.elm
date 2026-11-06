module AstralCharLiteralTest exposing (main)

{-| A `Char` literal above U+FFFF has its full code point: `'\u{1F600}'` is 128512, and equals `Char.fromCode 0x0001F600`.

A literal in the Basic Multilingual Plane, `'\u{20AC}'`, is checked as well.

-}

-- CHECK: astral: 128512
-- CHECK: bmp: 8364
-- CHECK: sameAsFromCode: True

import Html exposing (text)


main =
    let
        _ =
            Debug.log "astral" (Char.toCode '\u{1F600}')

        _ =
            Debug.log "bmp" (Char.toCode '\u{20AC}')

        _ =
            Debug.log "sameAsFromCode" ('\u{1F600}' == Char.fromCode 0x0001F600)
    in
    text "done"
