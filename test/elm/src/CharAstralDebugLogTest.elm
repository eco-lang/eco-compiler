module CharAstralDebugLogTest exposing (main)

{-| Debug.log of an astral Char prints the Char itself in quotes, as Elm's
Debug.toString does ('😀', emitted as UTF-8), boxed and unboxed. A BMP non-ASCII
Char prints as itself too.
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
