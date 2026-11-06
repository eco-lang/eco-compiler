module CharAstralDebugLogTest exposing (main)

{-| `Debug.log` prints an astral `Char` (code point above 0xFFFF) as the
character itself in single quotes, whether written as a literal, made with
`Char.fromCode`, or inside `Just`, and prints a non-ASCII character below
0xFFFF, `'€'`, the same way.
-}

-- CHECK: dbg_astral: '😀'
-- CHECK: dbg_fromcode: '𝄞'
-- CHECK: dbg_bmp: '€'
-- CHECK: dbg_maybe: Just '😀'


import Html exposing (text)


main =
    let
        _ =
            Debug.log "dbg_astral" '😀'

        _ =
            Debug.log "dbg_fromcode" (Char.fromCode 0x0001D11E)

        _ =
            Debug.log "dbg_bmp" '€'

        _ =
            Debug.log "dbg_maybe" (Just '😀')
    in
    text "done"
